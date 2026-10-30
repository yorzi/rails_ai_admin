# frozen_string_literal: true

require "support/operations"
require_relative "../../app/jobs/rails_ai_admin/collections/execution_job"

class CollectionContractPolicy < TestPolicy
  class_attribute :receipt_grant, :cancel_grant, :selection_grant, default: true
  class_attribute :class_grant, default: true
  class_attribute :read_hook
  def fields(**options)
    self.class.read_hook&.call if options[:action] == :read
    super
  end
  def select_records?(context:, resource:) = selection_grant && context.actor.id == 1
  def allowed?(context:, action:, resource:, record: nil)
    return super unless resource.operation_declarations.key?(action.to_sym)
    !denied && context.actor.id == 1 && (record ? record.points < 100 : class_grant)
  end
  def operation_fields(context:, resource:, operation:, record: nil) = context.actor.id == 1 && (record || class_grant) ? %i[amount note] : []
  def read_operation_receipt?(context:, resource:, operation:, record:) = receipt_grant && context.actor.id == 1
  def cancel_operation?(context:, resource:, operation:) = cancel_grant && context.actor.id == 1
  def deliver_work?(**) = true
end

class CollectionContractOperation < RailsAiAdmin::Operation
  lease_duration 5
  execution_window 60
  max_duration 1
  input do
    integer :amount, required: true, nullable: false
    text :note, required: true, max_length: 80
  end
  class_attribute :hook, :enqueue_work, :preflight_hook
  def preflight(_context, record, input)
    self.class.preflight_hook&.call
    { points: record.points + input.fetch("amount") }
  end
  def perform(context, record, input)
    return invalid(:note) if record.name == "Reject this record"
    self.class.hook&.call(record)
    record.update!(points: record.points + input.fetch("amount"), name: input.fetch("note"))
    context.outbox.enqueue("customers.reviewed", customer_ref: context.ref(record)) if self.class.enqueue_work
    success(record)
  end
end

class CollectionCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :batch_customers
  title :name
  fields do
    id :id
    text :name
    integer :points
  end
  operation :award, handler: "CollectionContractOperation", scope: :collection
end

module CollectionContractHelpers
  def with_collection
    CollectionContractPolicy.denied = false
    CollectionContractPolicy.class_grant = true
    CollectionContractPolicy.read_hook = nil
    CollectionContractPolicy.receipt_grant = CollectionContractPolicy.cancel_grant = CollectionContractPolicy.selection_grant = true
    CollectionContractOperation.hook = nil
    CollectionContractOperation.preflight_hook = nil
    CollectionContractOperation.enqueue_work = false
    OperationJobContext.epoch = "1"
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "OperationJobContext"
    config.authorization_adapter = "CollectionContractPolicy"
    config.resources = [ "CollectionCustomerAdmin" ]
    config.work_handlers = { "customers.reviewed" => "OperationContractWork" }
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
    CollectionContractOperation.hook = nil
    CollectionContractPolicy.read_hook = nil
  end

  def selection(ids = [ @customer.id, @second.id ])
    RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin, target_ids: ids)
  end

  def proposal(selection_ref: selection.selection_ref, input: { "amount" => "08", "note" => "Awarded" })
    RailsAiAdmin::Collections::Runner.new.preflight(context: context, resource: CollectionCustomerAdmin,
      operation: :award, selection_ref: selection_ref, input: input)
  end

  def admit(proposed = proposal, input: proposed.values, **options)
    RailsAiAdmin::Collections::Runner.new.admit(context: context, intent_ref: proposed.intent.id,
      input: input, human_confirmed: true, **options)
  end
end
