# frozen_string_literal: true

require "test_helper"
require "support/operations"

class CustomOperationsTest < Minitest::Test
  include DatabaseHelpers
  include OperationContractHelpers

  def setup = reset_database

  def test_input_bound_pure_preview_commit_outbox_and_postcondition_safe_replay
    with_operations do
      proposal = propose
      assert_equal "Alice", @customer.reload.name
      assert_equal({ "name" => { "before" => "Alice", "after" => "Reviewed customer" } }, proposal.changes)
      refute_includes proposal.changes.inspect, "never expose"
      result = approve(proposal)
      assert result.success?, result.code
      assert_equal 1, @customer.reload.points
      assert_equal 1, RailsAiAdmin::WorkItem.count
      assert_equal 1, RailsAiAdmin::WorkItem.first.expected_version
      assert_equal [ RailsAiAdmin::WorkItem.first.id ], result.work_refs
      replay = approve(proposal)
      assert replay.replayed
      assert_equal result.audit_ref, replay.audit_ref
      assert_equal 1, @customer.reload.lock_version
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      OperationContractPolicy.input_grant = false
      assert approve(proposal).replayed
      OperationContractPolicy.receipt_grant = false
      assert_equal "NOT_FOUND", approve(proposal).code
    end
  end

  def test_input_and_human_evidence_are_independent_of_ordinary_write_fields
    with_operations do
      proposal = propose
      runner = RailsAiAdmin::Operations::Runner.new
      assert_equal "APPROVAL_REQUIRED", runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values).code
      assert_equal "APPROVAL_INVALIDATED", approve(proposal, input: { "note" => "Changed after preview" }).code
      OperationContractPolicy.input_grant = false
      assert_equal "NOT_FOUND", approve(proposal).code
      assert_equal "Alice", @customer.reload.name
      assert_empty RailsAiAdmin::WorkItem.all
      assert_raises(RailsAiAdmin::AccessDenied) { propose(resource: ReadonlyContractAdmin) }
    end
  end

  def test_invalid_domain_outcome_and_late_failure_roll_back_domain_audit_and_outbox
    with_operations do
      result = approve(propose(operation: :invalid))
      assert_equal "VALIDATION_FAILED", result.code
      assert_equal({ "note" => [ "is invalid" ] }, result.errors)
      assert_equal "Alice", @customer.reload.name
      ReviewContractOperation.after_enqueue = ->(_record) { raise ActiveRecord::Rollback }
      result = approve
      assert_equal "VALIDATION_FAILED", result.code
      assert_equal "Alice", @customer.reload.name
      assert_empty RailsAiAdmin::WorkItem.all
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end

  def test_preview_writes_and_service_savepoints_are_rejected
    with_operations do
      assert_raises(RailsAiAdmin::ConfigurationError) { propose(operation: :impure) }
      assert_equal "Alice", @customer.reload.name
      proposal = propose(operation: :nested)
      assert_raises(RailsAiAdmin::ConfigurationError) { approve(proposal) }
      assert_equal "Alice", @customer.reload.name
      assert_equal "proposed", proposal.intent.reload.status
    end
  end

  def test_unversioned_custom_writes_cannot_consume_stale_confirmations
    with_operations do
      first = propose(operation: :unversioned)
      second = propose(operation: :unversioned)
      [ first, second ].each do |proposal|
        assert_raises(RailsAiAdmin::ConfigurationError) { approve(proposal) }
        assert_equal "proposed", proposal.intent.reload.status
      end
      assert_equal "Alice", @customer.reload.name
      assert_equal 0, @customer.lock_version
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end

  def test_receipt_replay_does_not_describe_ungranted_input_fields
    with_operations do
      proposal = propose
      assert approve(proposal).success?
      result = approve(proposal, input: { "note" => "Reviewed customer", "hidden_counter" => "not-a-number" })
      assert_equal "IDEMPOTENCY_CONFLICT", result.code
      assert_empty result.errors
      assert_equal 1, @customer.reload.lock_version
      assert_equal 1, RailsAiAdmin::WorkItem.count
    end
  end

  def test_custom_preflight_also_protects_the_target_lookup_from_callback_writes
    with_operations do
      callback = -> { update!(name: "Side effect from a read callback") }
      Customer.set_callback(:find, :after, callback)
      begin
        proposal = propose
        assert_equal "OPERATION_FAILED", proposal.code
        assert_empty RailsAiAdmin::OperationRun.all
        assert_empty RailsAiAdmin::WorkItem.all
      ensure
        Customer.skip_callback(:find, :after, callback)
      end
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_intent_target_identity_is_canonicalized_from_the_scoped_record
    with_operations do
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(context: context, resource: ContractCustomerAdmin, operation: :review,
        target_id: "000#{@customer.id}", expected_version: @customer.lock_version, input: { "note" => "Reviewed customer" })
      assert_equal @customer.id.to_s, proposal.intent.target_id
      assert approve(proposal).success?
    end
  end
end
