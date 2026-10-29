# frozen_string_literal: true

require "test_helper"
require "support/operations"
require "active_support/testing/time_helpers"

class OutboxTest < Minitest::Test
  include DatabaseHelpers
  include OperationContractHelpers
  include ActiveSupport::Testing::TimeHelpers

  def setup = reset_database
  def dispatcher = RailsAiAdmin::Outbox::Dispatcher.new

  def test_committed_work_uses_fresh_delivery_authority_and_its_own_lifetime
    with_operations do
      calls = []
      OperationContractWork.transport = lambda do |delivery, input|
        refute RailsAiAdmin::WorkItem.connection.transaction_open?
        assert delivery.assert_current!
        calls << [ delivery.actor_ref, delivery.tenant_ref, delivery.delivery_key, input ]
      end
      proposal = propose
      result = approve(proposal)
      assert_empty calls
      proposal.intent.update!(expires_at: 1.minute.ago)
      item = RailsAiAdmin::WorkItem.find(result.work_refs.first)
      assert_equal "pending", item.status
      assert_equal [ "customer_ref" ], item.payload.keys
      assert dispatcher.run(item.id).success?
      assert_equal 1, calls.size
      assert_equal context.actor_ref, calls.first[0]
      assert_equal context.tenant_ref, calls.first[1]
      assert dispatcher.run(item.id).success?
      assert_equal 1, calls.size
      assert_equal 1, item.reload.generation
      assert_equal "succeeded", proposal.intent.reload.status
    end
  end

  def test_scanner_recovers_a_missing_after_commit_enqueue
    with_operations do
      calls = 0
      OperationContractWork.transport = ->(_delivery, _input) { calls += 1 }
      approve
      assert_equal 1, dispatcher.scan_pending!(inline: true)
      assert_equal 1, calls
      assert_equal 0, dispatcher.scan_pending!(inline: true)
    end
  end

  def test_queue_failure_after_commit_keeps_the_business_receipt_and_pending_row
    with_operations do
      RailsAiAdmin.configuration.outbox_auto_dispatch = true
      result = RailsAiAdmin::Outbox::DeliveryJob.stub(:perform_later, ->(_id) { raise "queue unavailable" }) { approve }
      assert result.success?
      assert_equal "pending", RailsAiAdmin::WorkItem.find(result.work_refs.first).status
      assert_equal 1, dispatcher.scan_pending!(inline: true)
      assert_equal "succeeded", RailsAiAdmin::WorkItem.find(result.work_refs.first).status
    end
  end

  def test_aborted_queue_enqueue_is_not_counted_as_scheduled
    with_operations do
      approve
      count = RailsAiAdmin::Outbox::DeliveryJob.stub(:perform_later, false) { dispatcher.scan_pending! }
      assert_equal 0, count
      assert_equal "pending", RailsAiAdmin::WorkItem.first.status
      assert_equal 0, RailsAiAdmin::WorkItem.first.attempts
    end
  end

  def test_revocation_cancels_unsent_work_without_reversing_business_success
    with_operations do
      result = approve
      OperationJobContext.epoch = "2"
      item = RailsAiAdmin::WorkItem.find(result.work_refs.first)
      assert_equal "cancelled", dispatcher.run(item.id).status
      assert_nil item.reload.effect_started_at
      assert_equal "succeeded", RailsAiAdmin::OperationRun.find(item.operation_run_id).status
      assert_equal 1, @customer.reload.points
    end
  end

  def test_post_commit_record_changes_require_explicit_reconciliation
    with_operations do
      result = approve
      @customer.reload.update!(name: "Later legitimate edit")
      delivery = dispatcher.run(result.work_refs.first)
      assert_equal "reconciliation_required", delivery.status
      assert_equal "RECORD_CHANGED", delivery.code
      assert_nil RailsAiAdmin::WorkItem.find(delivery.work_ref).effect_started_at
    end
  end

  def test_delivery_deadline_and_attempt_budget_have_explicit_terminal_states
    with_operations do
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      item.update!(deadline_at: 1.second.ago)
      assert_equal "failed", dispatcher.run(item.id).status
      assert_equal "WORK_EXPIRED", item.reload.last_code
      assert_nil item.effect_started_at
      @customer.reload.update!(points: 0)
      retry_item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      OperationContractWork.before_effect = ->(_delivery) { raise "cannot start delivery" }
      assert_equal "pending", dispatcher.run(retry_item.id).status
      travel 3.seconds do
        assert_equal "pending", dispatcher.run(retry_item.id).status
      end
      travel 8.seconds do
        assert_equal "failed", dispatcher.run(retry_item.id).status
      end
      assert_equal 3, retry_item.reload.attempts
      assert_nil retry_item.effect_started_at
    end
  end

  def test_reused_worker_rebuilds_tenant_context_and_restores_write_permissions
    with_operations do
      observed = []
      OperationContractWork.transport = ->(delivery, _input) { observed << [ delivery.tenant_ref, delivery.record.account_id ] }
      first = approve
      other_context = context(tenant: 2)
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(context: other_context, resource: ContractCustomerAdmin, operation: :review,
        target_id: @other.id, expected_version: @other.lock_version, input: { "note" => "Tenant B review" })
      second = RailsAiAdmin::Operations::Runner.new.execute(context: other_context, intent_ref: proposal.intent.id,
        input: proposal.values, human_confirmed: true)
      worker = dispatcher
      assert worker.run(first.work_refs.first).success?
      assert worker.run(second.work_refs.first).success?
      assert_equal [ [ context.tenant_ref, 1 ], [ other_context.tenant_ref, 2 ] ], observed
      assert Customer.create!(account_id: 1, name: "Writes restored after delivery").persisted?
    end
  end

  def test_changed_target_connection_pool_is_not_accepted_for_delivery
    with_operations do
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      Customer.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
      begin
        result = dispatcher.run(item.id)
        assert_equal "reconciliation_required", result.status
        assert_equal "CONNECTION_CHANGED", result.code
        assert_nil item.reload.effect_started_at
      ensure
        Customer.remove_connection
      end
    end
  end

  def test_idempotent_retry_reuses_the_key_after_response_loss
    with_operations do
      applied, keys, lose_response = {}, [], true
      OperationContractWork.transport = lambda do |delivery, _input|
        keys << delivery.delivery_key
        applied[delivery.delivery_key] ||= "downstream receipt"
        raise "private provider response must never be stored" if lose_response
        applied.fetch(delivery.delivery_key)
      end
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      assert_equal "pending", dispatcher.run(item.id).status
      assert_equal "DELIVERY_FAILED", item.reload.last_code
      refute_includes item.attributes.inspect, "private provider"
      lose_response = false
      travel 3.seconds do
        assert dispatcher.run(item.id).success?
      end
      assert_equal 2, keys.size
      assert_equal 1, keys.uniq.size
      assert_equal 1, applied.size
      assert_equal 2, item.reload.attempts
    end
  end

  def test_non_idempotent_unknown_effect_is_not_retried
    with_operations do
      ReviewContractOperation.work_kind = "customers.non_idempotent"
      calls = 0
      OperationContractWork.transport = ->(_delivery, _input) { calls += 1; raise "lost response" }
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      assert_equal "reconciliation_required", dispatcher.run(item.id).status
      assert_equal "reconciliation_required", dispatcher.run(item.id).status
      assert_equal 1, calls
      assert_equal 1, item.reload.attempts
    end
  end

  def test_changed_external_request_is_not_sent_under_an_existing_delivery_key
    with_operations do
      calls = 0
      OperationContractWork.transport = ->(_delivery, _input) { calls += 1; raise "lost response" }
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      assert_equal "pending", dispatcher.run(item.id).status
      OperationContractWork.request_builder = ->(_delivery, input) { input.merge("unexpected_body_change" => true) }
      travel 3.seconds do
        result = dispatcher.run(item.id)
        assert_equal "reconciliation_required", result.status
        assert_equal "REQUEST_CHANGED", result.code
      end
      assert_equal 1, calls
    end
  end

  def test_revocation_after_an_unknown_effect_does_not_become_cancelled
    with_operations do
      OperationContractWork.transport = ->(_delivery, _input) { raise "lost response" }
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      assert_equal "pending", dispatcher.run(item.id).status
      OperationContractPolicy.delivery_grant = false
      travel 3.seconds do
        assert_equal "reconciliation_required", dispatcher.run(item.id).status
      end
    end
  end

  def test_work_definition_is_checked_again_at_effect_admission
    with_operations do
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      OperationContractWork.before_effect = ->(_delivery) { OperationContractWork.version("changed") }
      calls = 0
      OperationContractWork.transport = ->(_delivery, _input) { calls += 1 }
      result = dispatcher.run(item.id)
      assert_equal "HANDLER_CHANGED", result.code
      assert_equal "reconciliation_required", result.status
      assert_equal 0, calls
      assert_nil item.reload.effect_started_at
    ensure
      OperationContractWork.version("1")
    end
  end

  def test_work_cannot_mutate_business_records_through_normal_active_record_apis
    with_operations do
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      OperationContractWork.before_effect = ->(delivery) { delivery.record.update!(name: "Unaudited mutation") }
      assert_equal "pending", dispatcher.run(item.id).status
      assert_equal "Reviewed customer", @customer.reload.name
      assert_nil item.reload.effect_started_at
      OperationContractWork.before_effect = nil
      OperationContractWork.transport = ->(delivery, _input) { delivery.record.update!(name: "Unaudited effect mutation") }
      travel 3.seconds do
        assert_equal "pending", dispatcher.run(item.id).status
      end
      assert_equal "Reviewed customer", @customer.reload.name
    end
  end

  def test_known_success_survives_late_revocation_and_callback_failure
    with_operations do
      OperationContractWork.transport = lambda do |_delivery, _input|
        OperationContractPolicy.delivery_grant = false
        true
      end
      OperationContractWork.after_effect = ->(_delivery) { raise "local callback failed after the known delivery" }
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      assert dispatcher.run(item.id).success?
      assert_equal "succeeded", item.reload.status
      assert_equal "POST_EFFECT_CALLBACK_FAILED", item.last_code
    end
  end

  def test_fencing_stops_a_resumed_worker_before_its_effect
    with_operations do
      entered, release = Queue.new, Queue.new
      calls = 0
      OperationContractWork.before_effect = lambda do |delivery|
        if delivery.generation == 1
          entered << true
          release.pop
        end
      end
      OperationContractWork.transport = ->(_delivery, _input) { calls += 1 }
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { dispatcher.run(item.id) } }
      assert entered.pop(timeout: 5)
      item.update!(lease_expires_at: 1.second.ago)
      assert dispatcher.run(item.id).success?
      release << true
      assert thread.join(5)
      assert_equal "FENCED", thread.value.code
      assert_equal 1, calls
      assert_equal 2, item.reload.generation
      assert_equal "succeeded", item.status
    ensure
      release << true if release
      thread&.kill&.join if thread&.alive?
    end
  end

  def test_stale_response_cannot_overwrite_a_new_workers_receipt
    with_operations do
      entered, release = Queue.new, Queue.new
      applied = {}
      OperationContractWork.transport = lambda do |delivery, _input|
        applied[delivery.delivery_key] ||= "receipt"
        if delivery.generation == 1
          entered << true
          release.pop
        end
        applied.fetch(delivery.delivery_key)
      end
      item = RailsAiAdmin::WorkItem.find(approve.work_refs.first)
      thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { dispatcher.run(item.id) } }
      assert entered.pop(timeout: 5)
      item.update!(lease_expires_at: 1.second.ago)
      assert dispatcher.run(item.id).success?
      release << true
      assert thread.join(5)
      assert_equal "FENCED", thread.value.code
      assert_equal 1, applied.size
      assert_equal 2, item.reload.generation
      assert_equal "succeeded", item.status
    ensure
      release << true if release
      thread&.kill&.join if thread&.alive?
    end
  end
end
