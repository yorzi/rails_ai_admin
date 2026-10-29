# frozen_string_literal: true

require "support/database"
require "minitest/mock"
require_relative "../../app/jobs/rails_ai_admin/outbox/delivery_job"

class OperationContractPolicy < TestPolicy
  class_attribute :receipt_grant, default: true
  class_attribute :delivery_grant, default: true
  class_attribute :input_grant, default: true

  def allowed?(context:, action:, resource:, record: nil)
    return super unless resource.operation_declarations.key?(action.to_sym)
    !denied && context.actor.id == 1 && record.points.to_i.zero?
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    !denied && input_grant && context.actor.id == 1 ? [ :note ] : []
  end

  def read_operation_receipt?(context:, resource:, operation:, record:)
    !denied && receipt_grant && context.actor.id == 1
  end

  def deliver_work?(context:, resource:, operation:, work_kind:, record:)
    !denied && delivery_grant && context.actor.id == 1 && operation == :review && work_kind.start_with?("customers.")
  end
end

class OperationJobContext
  class_attribute :epoch, default: "1"
  def resolve(controller)
    id = controller.session[:actor_id]
    return unless id
    RailsAiAdmin::Context.new(actor: TestActor.new(id), tenant: TestTenant.new(1), security_version: self.class.epoch)
  end
  def resolve_job(actor_ref:, tenant_ref:, security_version:)
    return unless actor_ref.match?(/\Araa:actor:TestActor:\d+\z/) && tenant_ref.match?(/\Araa:tenant:TestTenant:\d+\z/)
    RailsAiAdmin::Context.new(actor: TestActor.new(actor_ref.split(":").last.to_i), tenant: TestTenant.new(tenant_ref.split(":").last.to_i), security_version: self.class.epoch)
  end
end

class OperationContractWork < RailsAiAdmin::Work
  idempotent true
  input { text :customer_ref, required: true, nullable: false, max_length: 150 }
  class_attribute :before_effect, :transport, :after_effect, :request_builder

  def perform(context, input)
    self.class.before_effect&.call(context)
    request = self.class.request_builder ? self.class.request_builder.call(context, input) : input
    result = context.effect(request: request) { |delivery| self.class.transport.call(delivery, input) }
    self.class.after_effect&.call(context)
    result
  end
end

class NonIdempotentContractWork < RailsAiAdmin::Work
  input { text :customer_ref, required: true, nullable: false, max_length: 150 }
  def perform(context, input)
    context.effect(request: input) { |delivery| OperationContractWork.transport.call(delivery, input) }
  end
end

class ReviewContractOperation < RailsAiAdmin::Operation
  input do
    text :note, required: true, nullable: false, max_length: 80
    integer :hidden_counter
  end
  class_attribute :work_kind, default: "customers.reviewed"
  class_attribute :after_enqueue

  def preflight(_context, _record, input)
    { name: input.fetch("note"), secret: "never expose this preview" }
  end

  def perform(context, record, input)
    record.update!(name: input.fetch("note"), points: 1)
    2.times { context.outbox.enqueue(self.class.work_kind, customer_ref: context.ref(record)) }
    self.class.after_enqueue&.call(record)
    success(record)
  end
end

class InvalidContractOperation < RailsAiAdmin::Operation
  input { text :note, required: true }
  def perform(_context, record, _input)
    record.update!(name: "Must roll back")
    invalid(:note)
  end
end

class NestedContractOperation < RailsAiAdmin::Operation
  input { text :note, required: true }
  def perform(_context, record, _input)
    record.class.transaction(requires_new: true) { record.update!(name: "Must roll back") }
    success(record)
  end
end

class ImpureContractOperation < RailsAiAdmin::Operation
  input { text :note, required: true }
  def preflight(_context, record, _input)
    record.update!(name: "Forbidden preview write")
    {}
  end
  def perform(_context, record, _input) = success(record)
end

class UnversionedContractOperation < RailsAiAdmin::Operation
  input { text :note, required: true }
  def perform(_context, record, input)
    record.update_columns(name: input.fetch("note"))
    success(record)
  end
end

class FailingPreviewOperation < RailsAiAdmin::Operation
  input { text :note, required: true }
  def preflight(_context, _record, _input)
    raise "sensitive preview diagnostic"
  end
  def perform(_context, record, _input) = success(record)
end

class ContractCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :contract_customers
  title :name
  fields do
    id :id
    text :name
    integer :points
    text :secret
  end
  operation :review, handler: "ReviewContractOperation"
  operation :invalid, handler: "InvalidContractOperation"
  operation :nested, handler: "NestedContractOperation"
  operation :impure, handler: "ImpureContractOperation"
  operation :unversioned, handler: "UnversionedContractOperation"
  operation :failing_preview, handler: "FailingPreviewOperation"
end

class ReadonlyContractAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :readonly_contracts
  title :name
  readonly
  fields { text :name }
  operation :review, handler: "ReviewContractOperation"
end

module OperationContractHelpers
  def with_operations
    OperationContractPolicy.denied = false
    OperationContractPolicy.receipt_grant = OperationContractPolicy.delivery_grant = OperationContractPolicy.input_grant = true
    OperationJobContext.epoch = "1"
    ReviewContractOperation.work_kind = "customers.reviewed"
    ReviewContractOperation.after_enqueue = nil
    OperationContractWork.before_effect = nil
    OperationContractWork.after_effect = nil
    OperationContractWork.request_builder = nil
    OperationContractWork.transport = ->(_delivery, _input) { true }
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "OperationJobContext"
    config.authorization_adapter = "OperationContractPolicy"
    config.resources = %w[ContractCustomerAdmin ReadonlyContractAdmin]
    config.work_handlers = { "customers.reviewed" => "OperationContractWork", "customers.non_idempotent" => "NonIdempotentContractWork" }
    registry = RailsAiAdmin::Registry.new(config.resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    work = RailsAiAdmin::Outbox::Registry.new(config.work_handlers)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          RailsAiAdmin.stub(:work_registry, work) { yield }
        end
      end
    end
  ensure
    OperationContractWork.before_effect = nil
    OperationContractWork.after_effect = nil
    OperationContractWork.request_builder = nil
    ReviewContractOperation.after_enqueue = nil
  end

  def propose(operation: :review, input: { "note" => "Reviewed customer" }, resource: ContractCustomerAdmin)
    RailsAiAdmin::Operations::Runner.new.preflight(context: context, resource: resource, operation: operation,
      target_id: @customer.id, expected_version: @customer.lock_version, input: input)
  end

  def approve(proposal = propose, input: { "note" => "Reviewed customer" })
    RailsAiAdmin::Operations::Runner.new.execute(context: context, intent_ref: proposal.intent.id, input: input, human_confirmed: true)
  end
end
