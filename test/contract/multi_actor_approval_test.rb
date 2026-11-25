# frozen_string_literal: true

require "test_helper"
require "support/operations"

# E06 Delta 2 (ADR 0026): multi-actor approval and separation of duties.
class MultiActorOperation < RailsAiAdmin::Operation
  input { text :note, required: true, nullable: false, max_length: 80 }

  def preflight(_context, _record, input)
    { name: input.fetch("note") }
  end

  def perform(_context, record, input)
    record.update!(name: input.fetch("note"), points: 10)
    success(record)
  end
end

class MultiActorCollectionOperation < RailsAiAdmin::Operation
  input { text :note, required: true, nullable: false, max_length: 80 }

  def preflight(_context, _record, input)
    { name: input.fetch("note") }
  end

  def perform(_context, record, input)
    record.update!(name: input.fetch("note"))
    success(record)
  end
end

class DualControlCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :dual_customers
  title :name
  fields do
    id :id
    text :name
    integer :points
  end
  operation :refund, handler: "MultiActorOperation", approval: :separate_actor, surface: true, assistant: true
  operation :peer_review, handler: "MultiActorOperation", approval: :any_reviewer
  operation :bulk_refund, handler: "MultiActorCollectionOperation", scope: :collection, approval: :separate_actor
end

class MultiActorPolicy < OperationContractPolicy
  class_attribute :reviewer_ids, default: [ 2 ]
  class_attribute :allowed_actor_ids, default: [ 1, 2 ]

  def select_records?(context:, resource:) = !denied && allowed_actor_ids.include?(context.actor.id)

  def allowed?(context:, action:, resource:, record: nil)
    return super unless resource.operation_declarations.key?(action.to_sym)
    !denied && allowed_actor_ids.include?(context.actor.id)
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    !denied && input_grant && allowed_actor_ids.include?(context.actor.id) ? [ :note ] : []
  end

  def read_operation_receipt?(context:, resource:, operation:, record:)
    !denied && receipt_grant && allowed_actor_ids.include?(context.actor.id)
  end

  def approve_operation?(context:, resource:, operation:, record: nil, proposed_by_actor_ref: nil)
    !denied && reviewer_ids.include?(context.actor.id)
  end
end

class MultiActorApprovalTest < Minitest::Test
  include DatabaseHelpers
  include OperationContractHelpers

  def setup
    reset_database
    MultiActorPolicy.denied = false
    MultiActorPolicy.reviewer_ids = [ 2 ]
    MultiActorPolicy.allowed_actor_ids = [ 1, 2 ]
    MultiActorPolicy.receipt_grant = true
    MultiActorPolicy.input_grant = true
    OperationJobContext.epoch = "1"
  end

  def with_dual_control(&block)
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "OperationJobContext"
    config.authorization_adapter = "MultiActorPolicy"
    config.resources = %w[DualControlCustomerAdmin]
    registry = RailsAiAdmin::Registry.new(config.resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    work = RailsAiAdmin::Outbox::Registry.new({})
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          RailsAiAdmin.stub(:work_registry, work, &block)
        end
      end
    end
  ensure
    OperationJobContext.epoch = "1"
  end

  def test_separate_actor_blocks_self_approval_and_allows_authorized_second_reviewer
    with_dual_control do
      proposer = context(actor: 1)
      reviewer = context(actor: 2)
      unprivileged = context(actor: 3)
      foreign_tenant = context(actor: 2, tenant: 2)

      runner = RailsAiAdmin::Operations::Runner.new
      proposal = runner.preflight(context: proposer, resource: DualControlCustomerAdmin, operation: :refund,
        target_id: @customer.id, expected_version: @customer.lock_version, input: { "note" => "Approved refund" })

      assert_equal "separate_actor", proposal.intent.approval_mode
      assert_equal proposer.actor_ref, proposal.intent.proposed_by_actor_ref
      assert_equal({ "note" => "Approved refund" }, proposal.intent.input_payload)

      # 1. Self-approval by proposer (even if proposer were in reviewer_ids) is forbidden.
      MultiActorPolicy.reviewer_ids = [ 1, 2 ]
      self_attempt = runner.execute(context: proposer, intent_ref: proposal.intent.id,
        input: { "note" => "Approved refund" }, human_confirmed: true)
      assert_equal "SELF_APPROVAL_FORBIDDEN", self_attempt.code
      assert_equal "Alice", @customer.reload.name
      assert_equal "proposed", proposal.intent.reload.status

      # 2. Cross-tenant reviewer is rejected as NOT_FOUND.
      foreign_attempt = runner.execute(context: foreign_tenant, intent_ref: proposal.intent.id,
        input: { "note" => "Approved refund" }, human_confirmed: true)
      assert_equal "NOT_FOUND", foreign_attempt.code

      # 3. Same-tenant actor without approve_operation? is rejected.
      MultiActorPolicy.allowed_actor_ids = [ 1, 2, 3 ]
      MultiActorPolicy.reviewer_ids = [ 2 ]
      denied_attempt = runner.execute(context: unprivileged, intent_ref: proposal.intent.id,
        input: { "note" => "Approved refund" }, human_confirmed: true)
      assert_equal "NOT_FOUND", denied_attempt.code
      assert_equal "Alice", @customer.reload.name

      # 4. Authorized second actor confirms; audit and run record both proposer and approver.
      approved = runner.execute(context: reviewer, intent_ref: proposal.intent.id,
        input: { "note" => "Approved refund" }, human_confirmed: true, approval_note: "Verified invoice match")
      assert_equal "OK", approved.code
      assert_equal "Approved refund", @customer.reload.name

      run = proposal.intent.reload
      assert_equal "succeeded", run.status
      assert_equal proposer.actor_ref, run.proposed_by_actor_ref
      assert_equal reviewer.actor_ref, run.approved_by_ref
      assert_equal reviewer.actor_ref, run.actor_ref
      assert_equal reviewer.security_version, run.approver_security_version
      assert_equal "Verified invoice match", run.approval_note

      audit = RailsAiAdmin::AuditEvent.find(run.audit_event_id)
      assert_equal reviewer.actor_ref, audit.actor_ref
      assert_equal proposer.actor_ref, audit.proposed_by_actor_ref

      # 5. Concurrent / second approve replays idempotently instead of double-writing.
      replay = runner.execute(context: reviewer, intent_ref: run.id,
        input: { "note" => "Approved refund" }, human_confirmed: true)
      assert_equal "OK", replay.code
      assert replay.replayed
    end
  end

  def test_any_reviewer_allows_proposer_only_when_granted_approve_operation
    with_dual_control do
      proposer = context(actor: 1)
      runner = RailsAiAdmin::Operations::Runner.new
      proposal = runner.preflight(context: proposer, resource: DualControlCustomerAdmin, operation: :peer_review,
        target_id: @customer.id, expected_version: @customer.lock_version, input: { "note" => "Peer checked" })

      # Actor 1 is not in reviewer_ids ([2]) -> denied.
      denied = runner.execute(context: proposer, intent_ref: proposal.intent.id,
        input: { "note" => "Peer checked" }, human_confirmed: true)
      assert_equal "NOT_FOUND", denied.code

      # Grant actor 1 reviewer permission -> allowed in any_reviewer mode.
      MultiActorPolicy.reviewer_ids = [ 1, 2 ]
      ok = runner.execute(context: proposer, intent_ref: proposal.intent.id,
        input: { "note" => "Peer checked" }, human_confirmed: true)
      assert_equal "OK", ok.code
      assert_equal "Peer checked", @customer.reload.name
    end
  end

  def test_collection_separate_actor_admission_runs_workers_under_approver_authority
    bob = Customer.create!(account_id: 1, name: "Bob", points: 0)
    with_dual_control do
      proposer = context(actor: 1)
      reviewer = context(actor: 2)
      selection = RailsAiAdmin::Selections::Builder.new.capture(context: proposer, resource: DualControlCustomerAdmin,
        target_ids: [ @customer.id.to_s, bob.id.to_s ])

      crunner = RailsAiAdmin::Collections::Runner.new
      proposal = crunner.preflight(context: proposer, resource: DualControlCustomerAdmin, operation: :bulk_refund,
        selection_ref: selection.selection_ref, input: { "note" => "Batch reviewed" })

      # Self-admission rejected.
      self_res = crunner.admit(context: proposer, intent_ref: proposal.intent.id,
        input: { "note" => "Batch reviewed" }, human_confirmed: true)
      assert_equal "SELF_APPROVAL_FORBIDDEN", self_res.code

      # Reviewer admits and worker executes under reviewer's live authority.
      admitted = crunner.admit(context: reviewer, intent_ref: proposal.intent.id,
        input: { "note" => "Batch reviewed" }, human_confirmed: true)
      assert_equal "QUEUED", admitted.code

      dispatched = RailsAiAdmin::Collections::Dispatcher.new.run(admitted.job_ref)
      assert_equal "succeeded", dispatched.status
      assert_equal [ "Batch reviewed", "Batch reviewed" ], [ @customer.reload.name, bob.reload.name ]

      parent = proposal.intent.reload
      assert_equal proposer.actor_ref, parent.proposed_by_actor_ref
      assert_equal reviewer.actor_ref, parent.approved_by_ref
      assert_equal reviewer.actor_ref, parent.actor_ref

      # Proposer and reviewer can both read the collection receipt.
      snap_proposer = RailsAiAdmin::Collections::Queries.new.fetch(context: proposer, job_ref: parent.id)
      snap_reviewer = RailsAiAdmin::Collections::Queries.new.fetch(context: reviewer, job_ref: parent.id)
      assert_equal "succeeded", snap_proposer.status
      assert_equal "succeeded", snap_reviewer.status
    end
  end

  def test_changing_approval_mode_changes_operation_fingerprint
    with_dual_control do
      fp_separate = RailsAiAdmin::Operations::RunnerFingerprint.call(
        DualControlCustomerAdmin,
        RailsAiAdmin.operation_registry.fetch(DualControlCustomerAdmin, :refund)
      )
      fp_any = RailsAiAdmin::Operations::RunnerFingerprint.call(
        DualControlCustomerAdmin,
        RailsAiAdmin.operation_registry.fetch(DualControlCustomerAdmin, :peer_review)
      )
      refute_equal fp_separate, fp_any
    end
  end
end
