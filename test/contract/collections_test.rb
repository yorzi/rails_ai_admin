# frozen_string_literal: true

require "test_helper"
require "support/collections"

class CollectionsTest < Minitest::Test
  include DatabaseHelpers
  include CollectionContractHelpers
  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Second")
  end

  def test_one_parent_approval_durable_admission_and_per_item_atomic_execution
    with_collection do
      proposed = proposal
      assert_equal 2, proposed.targets.size
      assert_equal "Alice", @customer.reload.name
      assert_equal 0, RailsAiAdmin::BatchItem.count
      admitted = admit(proposed)
      assert admitted.accepted?, admitted.code
      assert_equal "queued", admitted.status
      assert_equal 2, RailsAiAdmin::BatchItem.count
      assert_equal 3, RailsAiAdmin::OperationRun.count
      assert_equal admitted.job_ref, admit(proposed).job_ref
      assert_equal 2, RailsAiAdmin::BatchItem.count
      parent = RailsAiAdmin::OperationRun.find(admitted.job_ref)
      assert_equal context.actor_ref, parent.approved_by_ref
      assert_equal 0, @customer.reload.points
      result = RailsAiAdmin::Collections::Dispatcher.new.run(admitted.job_ref)
      assert_equal "succeeded", result.status
      assert_equal [ 8, 8 ], [ @customer.reload.points, @second.reload.points ]
      assert_equal 2, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      children = RailsAiAdmin::OperationRun.where(parent_run_id: parent.id)
      assert_equal [ "succeeded" ], children.distinct.pluck(:status)
      assert_equal [ nil ], children.distinct.pluck(:confirmed_at)
      assert_equal [ nil ], children.distinct.pluck(:approved_by_ref)
      RailsAiAdmin::Collections::Dispatcher.new.run(parent.id)
      assert_equal 8, @customer.reload.points
    end
  end

  def test_approval_input_manifest_binding_and_direct_child_execution_are_closed
    with_collection do
      proposed = proposal
      runner = RailsAiAdmin::Collections::Runner.new
      assert_equal "APPROVAL_REQUIRED", runner.admit(context: context, intent_ref: proposed.intent.id, input: proposed.values).code
      assert_equal "APPROVAL_INVALIDATED", admit(proposed, input: proposed.values.merge("amount" => 9)).code
      result = admit(proposed)
      child = RailsAiAdmin::OperationRun.where(parent_run_id: result.job_ref).first
      audit_count = RailsAiAdmin::AuditEvent.count
      rejected = RailsAiAdmin::Operations::Runner.new.execute(context: context, intent_ref: child.id,
        input: proposed.values, human_confirmed: true)
      assert_equal "NOT_FOUND", rejected.code
      assert_equal audit_count, RailsAiAdmin::AuditEvent.count
      assert_equal 0, @customer.reload.points
      assert_raises(RailsAiAdmin::ConfigurationError) do
        RailsAiAdmin::Operations::Runner.new.prepare(context: context, resource: CollectionCustomerAdmin,
          operation: :award, target_id: @customer.id, expected_version: 0, input: proposed.values)
      end
    end
  end

  def test_partial_failure_and_cancel_preserve_committed_items
    with_collection do
      @second.update!(name: "Reject this record")
      accepted = admit
      finished = RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert_equal "partially_succeeded", finished.status
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      assert_equal 1, RailsAiAdmin::BatchItem.where(status: "failed", last_code: "VALIDATION_FAILED").count
    end
  end

  def test_approval_expiry_is_admission_only_and_execution_has_its_own_deadline
    with_collection do
      proposed = proposal
      accepted = admit(proposed)
      RailsAiAdmin::OperationRun.where(id: accepted.job_ref).update_all(expires_at: 1.second.ago)
      assert admit(proposed).accepted?
      RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert_equal 8, @customer.reload.points
      accepted = admit(proposal(selection_ref: selection.selection_ref))
      future = RailsAiAdmin::OperationRun.find(accepted.job_ref).execution_deadline + 1.second
      Time.stub(:current, future) do
        result = RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
        assert_equal "cancelled", result.status
      end
      assert_equal 8, @customer.reload.points
    end
  end
  def test_cancel_before_admission_and_after_claim_both_prevent_business_execution
    with_collection do
      proposed = proposal
      runner = RailsAiAdmin::Collections::Runner.new
      cancelled = runner.cancel(context: context, job_ref: proposed.intent.id)
      assert_equal "cancelled", cancelled.status
      assert_equal "CONFLICT", admit(proposed).code
      assert_empty RailsAiAdmin::BatchItem.all
      accepted = admit
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      claim = dispatcher.claim_next(accepted.job_ref)
      assert_nil dispatcher.claim_next(accepted.job_ref), "one in-flight item per parent"
      runner.cancel(context: context, job_ref: accepted.job_ref)
      result = RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: claim)
      assert_equal "FENCED", result.code
      assert_equal 0, @customer.reload.points
      assert_equal 2, RailsAiAdmin::BatchItem.where(status: "cancelled").count
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end

  def test_cancel_keeps_committed_children_and_their_outbox_work
    with_collection do
      CollectionContractOperation.enqueue_work = true
      accepted = admit
      RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref, limit: 1)
      cancelled = RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: accepted.job_ref)
      assert_equal "partially_succeeded", cancelled.status
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
      assert_equal 1, RailsAiAdmin::WorkItem.count
      assert_equal "pending", RailsAiAdmin::WorkItem.first.status
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
    end
  end

  def test_stale_success_failure_and_audit_writes_are_fenced_and_old_job_stops
    with_collection do
      accepted = admit
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      old = dispatcher.claim_next(accepted.job_ref)
      RailsAiAdmin::BatchItem.where(id: old.item_ref).update_all(lease_expires_at: 1.second.ago)
      fresh = dispatcher.claim_next(accepted.job_ref)
      assert_equal old.item_ref, fresh.item_ref
      assert_equal old.generation + 1, fresh.generation
      audit_count = RailsAiAdmin::AuditEvent.count
      dispatcher.send(:finish_rejected, old, RailsAiAdmin::Operations::Result.new(code: "OPERATION_FAILED"))
      assert_equal audit_count, RailsAiAdmin::AuditEvent.count
      assert_equal "running", RailsAiAdmin::BatchItem.find(fresh.item_ref).status
      calls = 0
      dispatcher.stub(:claim_next, ->(*) { calls += 1; old }) do
        dispatcher.run(accepted.job_ref)
      end
      assert_equal 1, calls, "a fenced job must not claim another item"
      assert RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: fresh).success?
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
    end
  end

  def test_expired_lease_before_commit_rolls_back_domain_audit_and_child_receipt
    with_collection do
      accepted = admit
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      claim = dispatcher.claim_next(accepted.job_ref)
      clock = Time.current
      CollectionContractOperation.hook = ->(_record) { clock += 6.seconds }
      Time.stub(:current, -> { clock }) do
        result = RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: claim)
        assert_equal "FENCED", result.code
        assert_equal 0, @customer.reload.points
        assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
        assert_equal "proposed", RailsAiAdmin::OperationRun.find(claim.operation_run_id).status
        CollectionContractOperation.hook = nil
        recovered = dispatcher.claim_next(accepted.job_ref)
        assert_equal claim.generation + 1, recovered.generation
        assert RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: recovered).success?
      end
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end

  def test_fresh_worker_epoch_and_per_record_scope_are_rechecked
    with_collection do
      accepted = admit
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      dispatcher.run(accepted.job_ref, limit: 1)
      OperationJobContext.epoch = "2"
      dispatcher.run(accepted.job_ref)
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
      assert_equal 1, RailsAiAdmin::BatchItem.where(status: "cancelled").count
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end

  def test_queue_loss_aborted_enqueue_and_pending_scan_are_recoverable
    with_collection do
      RailsAiAdmin.configuration.collection_auto_dispatch = true
      RailsAiAdmin::Collections::ExecutionJob.stub(:perform_later, ->(*) { raise "synthetic enqueue outage" }) do
        assert admit.accepted?
      end
      assert_equal 2, RailsAiAdmin::BatchItem.where(status: "queued").count
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      RailsAiAdmin::Collections::ExecutionJob.stub(:perform_later, false) do
        assert_equal 0, dispatcher.scan_pending!
      end
      RailsAiAdmin.configuration.collection_auto_dispatch = false
      assert_equal 1, dispatcher.scan_pending!(inline: true)
      assert_equal [ 8, 8 ], [ @customer.reload.points, @second.reload.points ]
    end
  end

  def test_payload_manifest_substitution_and_separate_cancel_grant_are_closed
    with_collection do
      proposed = proposal
      CollectionContractPolicy.cancel_grant = false
      assert_nil RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: proposed.intent.id).job_ref
      accepted = admit(proposed)
      parent = RailsAiAdmin::OperationRun.find(accepted.job_ref)
      pairs = parent.manifest_payload.deep_dup
      pairs[0][0] = @other.id.to_s
      RailsAiAdmin::OperationRun.where(id: parent.id).update_all(manifest_payload: pairs)
      result = RailsAiAdmin::Collections::Dispatcher.new.run(parent.id)
      assert_equal "reconciliation_required", result.status
      assert_equal 0, @customer.reload.points
      assert_equal 0, @other.reload.points
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end

  def test_receipt_replay_survives_own_command_postcondition_and_has_no_field_error_leaks
    with_collection do
      proposed = proposal(input: { "amount" => 100, "note" => "Finished" })
      accepted = admit(proposed)
      RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert admit(proposed).replayed
      mismatch = admit(proposed, input: { "amount" => {}, "note" => "Finished", "hidden" => true })
      assert_equal "IDEMPOTENCY_CONFLICT", mismatch.code
      assert_empty mismatch.errors
      CollectionContractPolicy.receipt_grant = false
      assert_equal "NOT_FOUND", admit(proposed).code
      assert_equal 100, @customer.reload.points
    end
  end
  def test_receipt_projection_cannot_commit_after_the_lease_expires
    with_collection do
      accepted = admit
      claim = RailsAiAdmin::Collections::Dispatcher.new.claim_next(accepted.job_ref)
      clock = Time.current
      CollectionContractPolicy.read_hook = -> { clock += 6.seconds }
      Time.stub(:current, -> { clock }) do
        result = RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: claim)
        assert_equal "FENCED", result.code
      end
      assert_equal 0, @customer.reload.points
      assert_equal "running", RailsAiAdmin::BatchItem.find(claim.item_ref).status
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end
  def test_late_failure_audit_cannot_finalize_an_expired_lease
    with_collection do
      @customer.update!(name: "Reject this record")
      proposed = proposal(selection_ref: selection([ @customer.id ]).selection_ref)
      accepted = admit(proposed)
      clock = Time.current
      callback = ->(event) { clock += 6.seconds if event.status == "rejected" }
      RailsAiAdmin::AuditEvent.set_callback(:create, :before, callback)
      begin
        Time.stub(:current, -> { clock }) { RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref) }
      ensure
        RailsAiAdmin::AuditEvent.skip_callback(:create, :before, callback)
      end
      assert_equal "running", RailsAiAdmin::BatchItem.first.status
      assert_empty RailsAiAdmin::AuditEvent.where(status: "rejected")
      assert_equal 0, @customer.reload.points
    end
  end
  def test_admission_revalidates_without_repeating_host_preflight_or_title_projection_under_lock
    with_collection do
      observed = []
      CollectionContractOperation.preflight_hook = -> { observed << RailsAiAdmin::OperationRun.connection.transaction_open? }
      proposed = proposal
      assert_equal [ false, false ], observed
      CollectionContractPolicy.read_hook = -> { flunk "Admission must not project titles under the parent lock" }
      accepted = admit(proposed)
      assert accepted.accepted?, accepted.code
      assert_equal [ false, false ], observed
      assert_equal 0, @customer.reload.points
    end
  end

  def test_worker_rechecks_current_collection_level_command_and_input_grants
    with_collection do
      accepted = admit
      CollectionContractPolicy.class_grant = false
      result = RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert_equal "cancelled", result.status
      assert_equal 0, @customer.reload.points
      assert_equal 0, @second.reload.points
      assert_equal 2, RailsAiAdmin::BatchItem.where(last_code: "AUTHORIZATION_REVOKED").count
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end
  def test_collection_preview_has_an_aggregate_cooperative_budget
    with_collection do
      clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      real_clock = Process.method(:clock_gettime)
      CollectionContractOperation.preflight_hook = -> { clock += 20 }
      CollectionContractOperation.stub(:max_duration, 30) do
        Process.stub(:clock_gettime, ->(kind, *args) { kind == Process::CLOCK_MONOTONIC ? clock : real_clock.call(kind, *args) }) do
          result = proposal
          assert_equal "TIMEOUT", result.code
        end
      end
      assert_empty RailsAiAdmin::OperationRun.all
      assert_equal 0, @customer.reload.points
    end
  end
  def test_rolled_back_handler_failures_retry_with_a_budget_and_stable_child_intents
    with_collection do
      accepted = admit
      CollectionContractOperation.hook = ->(_record) { raise "synthetic private handler failure" }
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      first = dispatcher.run(accepted.job_ref)
      assert_equal "queued", first.status
      assert_equal 2, RailsAiAdmin::BatchItem.where(status: "queued", attempts: 1).count
      assert_equal 0, @customer.reload.points
      child_refs = RailsAiAdmin::BatchItem.order(:position).pluck(:operation_run_id)
      CollectionContractOperation.hook = nil
      future = Time.current + 10.seconds
      Time.stub(:current, future) { dispatcher.run(accepted.job_ref) }
      assert_equal [ 8, 8 ], [ @customer.reload.points, @second.reload.points ]
      assert_equal child_refs, RailsAiAdmin::BatchItem.order(:position).pluck(:operation_run_id)
      assert_equal 2, RailsAiAdmin::BatchItem.where(attempts: 2, generation: 2, status: "succeeded").count
      assert_equal 2, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end

  def test_exhausted_crash_claims_stop_that_item_and_continue_other_targets
    with_collection do
      accepted = admit
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      first_ref = nil
      3.times do
        claim = dispatcher.claim_next(accepted.job_ref)
        first_ref ||= claim.item_ref
        assert_equal first_ref, claim.item_ref
        RailsAiAdmin::BatchItem.where(id: claim.item_ref).update_all(lease_expires_at: 1.second.ago)
      end
      result = dispatcher.run(accepted.job_ref)
      assert_equal "partially_succeeded", result.status
      assert_equal 1, RailsAiAdmin::BatchItem.where(status: "failed", last_code: "ATTEMPTS_EXHAUSTED").count
      assert_equal 1, RailsAiAdmin::BatchItem.where(status: "succeeded").count
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
    end
  end
  def test_admission_uncertainty_returns_existing_ref_and_never_creates_a_second_intent
    with_collection do
      proposed = proposal
      callback = ->(run) { raise "synthetic private callback failure" if run.selection_id && run.status == "queued" }
      RailsAiAdmin::OperationRun.set_callback(:commit, :after, callback)
      begin
        RailsAiAdmin::OperationRun.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
          result = admit(proposed)
          assert_equal "OUTCOME_UNKNOWN", result.code
          assert_equal proposed.intent.id, result.job_ref
          refute result.accepted?
        end
      ensure
        RailsAiAdmin::OperationRun.skip_callback(:commit, :after, callback)
      end
      assert_equal 2, RailsAiAdmin::BatchItem.count
      assert admit(proposed).replayed
      assert_equal 2, RailsAiAdmin::BatchItem.count
      assert_equal 0, @customer.reload.points
    end
  end

  def test_unexpected_collection_input_failures_return_scrubbed_results
    with_collection do
      ref = selection.selection_ref
      CollectionContractPolicy.stub(:new, -> { raise "synthetic private policy failure" }) do
        result = proposal(selection_ref: ref)
        assert_equal "OPERATION_FAILED", result.code
        assert_empty result.errors
      end
      assert_empty RailsAiAdmin::OperationRun.all
    end
  end
  def test_cancel_commit_uncertainty_preserves_the_existing_ref_for_safe_refresh
    with_collection do
      accepted = admit
      callback = ->(run) { raise "synthetic private callback" if run.cancellation_requested_at }
      RailsAiAdmin::OperationRun.set_callback(:commit, :after, callback)
      begin
        RailsAiAdmin::OperationRun.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
          result = RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: accepted.job_ref)
          assert_equal "OUTCOME_UNKNOWN", result.code
          assert_equal accepted.job_ref, result.job_ref
        end
      ensure
        RailsAiAdmin::OperationRun.skip_callback(:commit, :after, callback)
      end
      assert_equal 2, RailsAiAdmin::BatchItem.where(status: "cancelled").count
      assert_equal 0, @customer.reload.points
    end
  end
  def test_admission_cancel_claim_and_execution_refuse_unowned_outer_transactions
    with_collection do
      proposed = proposal
      RailsAiAdmin::OperationRun.transaction do
        assert_raises(RailsAiAdmin::ConfigurationError) { admit(proposed) }
      end
      accepted = admit(proposed)
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      claim = dispatcher.claim_next(accepted.job_ref)
      RailsAiAdmin::OperationRun.transaction do
        assert_raises(RailsAiAdmin::ConfigurationError) { dispatcher.claim_next(accepted.job_ref) }
        assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: accepted.job_ref) }
        assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: claim) }
      end
      assert_equal 0, @customer.reload.points
      assert RailsAiAdmin::Operations::Runner.new.execute_admitted(claim: claim).success?
    end
  end
end
