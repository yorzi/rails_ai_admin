# frozen_string_literal: true

require "test_helper"
require "support/collections"

class AsyncBulkOperationsTest < Minitest::Test
  include DatabaseHelpers
  include CollectionContractHelpers

  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Second")
  end

  def seed_customers(total)
    existing = Customer.where(account_id: 1).count
    needed = total - existing
    if needed > 0
      now = Time.current
      rows = Array.new(needed) do |i|
        { account_id: 1, name: "Bulk Target #{i}", points: 0, active: true, lock_version: 0, created_at: now, updated_at: now }
      end
      Customer.insert_all!(rows)
    end
    Customer.where(account_id: 1).order(:id).limit(total).pluck(:id)
  end

  def test_configuration_validates_async_bulk_limit_and_chunk_size
    config = RailsAiAdmin::Configuration.new
    assert_equal 1_000, config.async_bulk_limit
    assert_equal 50, config.async_bulk_chunk_size

    [ 99, 10_001, "500", nil ].each do |bad_limit|
      invalid = RailsAiAdmin::Configuration.new
      invalid.async_bulk_limit = bad_limit
      assert_raises(RailsAiAdmin::ConfigurationError) { invalid.finalize! }
    end

    [ 9, 101, "50", nil ].each do |bad_chunk|
      invalid = RailsAiAdmin::Configuration.new
      invalid.async_bulk_chunk_size = bad_chunk
      assert_raises(RailsAiAdmin::ConfigurationError) { invalid.finalize! }
    end
  end

  def test_large_selection_fails_sync_cap_and_succeeds_async_chunked_execution
    with_collection do
      ids = seed_customers(150)
      builder = RailsAiAdmin::Selections::Builder.new

      sync_err = assert_raises(RailsAiAdmin::AccessDenied) do
        builder.capture(context: context, resource: CollectionCustomerAdmin, target_ids: ids)
      end
      assert_equal "INVALID_QUERY", sync_err.code

      snap = builder.capture(context: context, resource: CollectionCustomerAdmin, target_ids: ids,
        max_items: RailsAiAdmin.configuration.async_bulk_limit)
      assert_equal 150, snap.targets.size

      sync_reval_err = assert_raises(RailsAiAdmin::AccessDenied) do
        builder.revalidate(context: context, selection_ref: snap.selection_ref, max_items: RailsAiAdmin::Selections::Builder::LIMIT)
      end
      assert_equal "INVALID_QUERY", sync_reval_err.code

      proposed = proposal(selection_ref: snap.selection_ref, input: { "amount" => 5, "note" => "Chunked" })
      assert proposed.sampled
      assert_equal 150, proposed.total_count
      assert_equal 25, proposed.targets.size

      accepted = admit(proposed)
      assert accepted.accepted?, accepted.code
      assert_equal 150, RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref).count

      enqueued_continuations = []
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      RailsAiAdmin::Collections::ExecutionJob.stub(:perform_later, ->(ref) { enqueued_continuations << ref; true }) do
        chunk1 = dispatcher.run(accepted.job_ref, limit: 50, enqueue_continuation: true)
        assert_equal "queued", chunk1.status
        assert_equal [ accepted.job_ref ], enqueued_continuations
        assert_equal 50, Customer.where(account_id: 1, points: 5).count

        chunk2 = dispatcher.run(accepted.job_ref, limit: 50, enqueue_continuation: true)
        assert_equal "queued", chunk2.status
        assert_equal [ accepted.job_ref, accepted.job_ref ], enqueued_continuations
        assert_equal 100, Customer.where(account_id: 1, points: 5).count

        chunk3 = dispatcher.run(accepted.job_ref, limit: 50, enqueue_continuation: true)
        assert_equal "succeeded", chunk3.status
        assert_equal 2, enqueued_continuations.size
        assert_equal 150, Customer.where(account_id: 1, points: 5).count
      end

      job_snapshot = RailsAiAdmin::Collections::Queries.new.fetch(context: context, job_ref: accepted.job_ref)
      assert_equal 150, job_snapshot.counts["succeeded"]
    end
  end

  # A worker that finds another worker's live lease, or nothing ready, must
  # not re-enqueue itself: the lease holder continues and scan_pending! is the
  # backstop. Otherwise each scan starts a job chain that spins until the
  # lease ends.
  def test_continuation_only_follows_a_chunk_that_used_its_whole_budget
    with_collection do
      ids = seed_customers(30)
      snap = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin, target_ids: ids)
      accepted = admit(proposal(selection_ref: snap.selection_ref))
      assert accepted.accepted?, accepted.code
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      enqueued = []
      RailsAiAdmin::Collections::ExecutionJob.stub(:perform_later, ->(ref) { enqueued << ref; true }) do
        item = RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref).order(:position).first
        item.update!(status: "running", lease_owner: SecureRandom.uuid, lease_expires_at: 1.minute.from_now, attempts: 1, generation: 1)
        dispatcher.run(accepted.job_ref, limit: 10, enqueue_continuation: true)
        assert_empty enqueued, "a worker blocked by a live lease must not re-enqueue itself"

        item.update!(status: "queued", lease_owner: nil, lease_expires_at: nil, attempts: 0)
        dispatcher.run(accepted.job_ref, limit: 10, enqueue_continuation: true)
        assert_equal [ accepted.job_ref ], enqueued

        dispatcher.run(accepted.job_ref, limit: 25, enqueue_continuation: true)
        assert_equal "succeeded", RailsAiAdmin::OperationRun.find(accepted.job_ref).status
        assert_equal [ accepted.job_ref ], enqueued, "a chunk that drained the job does not continue"
      end
    end
  end

  def test_native_update_async_bulk_run_supports_over_hundred_records
    with_collection do
      ids = seed_customers(120)
      snap = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin,
        target_ids: ids, max_items: RailsAiAdmin.configuration.async_bulk_limit)
      runner = RailsAiAdmin::Collections::Runner.new
      proposed = runner.preflight(context: context, resource: CollectionCustomerAdmin, operation: :update,
        selection_ref: snap.selection_ref, input: { "points" => 42 }, origin: :assistant)
      assert proposed.is_a?(RailsAiAdmin::Collections::Runner::Proposal), proposed.inspect
      assert proposed.sampled
      assert_equal 120, proposed.total_count
      assert_equal 25, proposed.targets.size

      accepted = runner.admit(context: context, intent_ref: proposed.intent.id, input: proposed.values, human_confirmed: true)
      assert accepted.accepted?, accepted.code

      dispatcher = RailsAiAdmin::Collections::Dispatcher.new
      dispatcher.run(accepted.job_ref, limit: 60)
      dispatcher.run(accepted.job_ref, limit: 60)
      assert_equal "succeeded", RailsAiAdmin::OperationRun.find(accepted.job_ref).status
      assert_equal 120, Customer.where(account_id: 1, points: 42).count
    end
  end

  def test_mid_batch_cancellation_and_epoch_revocation_between_chunks_preserve_committed_items
    with_collection do
      ids = seed_customers(150)
      snap = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin,
        target_ids: ids, max_items: 1_000)
      accepted = admit(proposal(selection_ref: snap.selection_ref))
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new

      dispatcher.run(accepted.job_ref, limit: 50)
      assert_equal 50, Customer.where(account_id: 1, points: 8).count

      cancelled = RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: accepted.job_ref)
      assert_equal "partially_succeeded", cancelled.status
      assert_equal 50, RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref, status: "succeeded").count
      assert_equal 100, RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref, status: "cancelled").count

      # Epoch revocation between chunk 1 and chunk 2 on a fresh run
      snap2 = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin,
        target_ids: Customer.where(account_id: 1).order(:id).limit(120).pluck(:id), max_items: 1_000)
      accepted2 = admit(proposal(selection_ref: snap2.selection_ref, input: { "amount" => 3, "note" => "Epoch check" }))
      dispatcher.run(accepted2.job_ref, limit: 50)
      OperationJobContext.epoch = "2"
      dispatcher.run(accepted2.job_ref, limit: 50)
      assert_equal 50, RailsAiAdmin::BatchItem.where(parent_run_id: accepted2.job_ref, status: "succeeded").count
      assert_equal 70, RailsAiAdmin::BatchItem.where(parent_run_id: accepted2.job_ref, status: "cancelled").count
    end
  end

  def test_expired_lease_mid_chunk_reclaimed_by_scan_pending_and_failed_subset_retry_links_parent
    with_collection do
      third = Customer.create!(account_id: 1, name: "Reject this record")
      fourth = Customer.create!(account_id: 1, name: "Reject this record")
      snap = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: CollectionCustomerAdmin,
        target_ids: [ @customer.id, @second.id, third.id, fourth.id ])
      accepted = admit(proposal(selection_ref: snap.selection_ref, input: { "amount" => 10, "note" => "Initial" }))
      dispatcher = RailsAiAdmin::Collections::Dispatcher.new

      # Simulate worker crash leaving item 1 with an expired running lease
      claim = dispatcher.claim_next(accepted.job_ref)
      RailsAiAdmin::BatchItem.where(id: claim.item_ref).update_all(lease_expires_at: 2.seconds.ago)
      assert_equal 1, dispatcher.scan_pending!(inline: true)
      assert_equal "partially_succeeded", RailsAiAdmin::OperationRun.find(accepted.job_ref).status
      assert_equal 2, RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref, status: "succeeded").count
      assert_equal 2, RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref, status: "failed").count

      # Fourth is moved out of tenant scope; third is fixed and edited (advancing lock_version!)
      fourth.update!(account_id: 2)
      third.update!(name: "Fixed for retry")
      assert_operator third.lock_version, :>, 0

      retry_outcome = RailsAiAdmin::Collections::Runner.new.retry_failed(context: context, job_ref: accepted.job_ref)
      assert_equal 1, retry_outcome.omitted_count
      assert_equal accepted.job_ref, retry_outcome.proposal.intent.retry_of_run_id
      assert_equal [ third.id.to_s ], retry_outcome.selection.targets.map(&:id)
      assert_equal [ third.lock_version ], retry_outcome.selection.targets.map(&:expected_version)

      retry_accepted = RailsAiAdmin::Collections::Runner.new.admit(
        context: context,
        intent_ref: retry_outcome.proposal.intent.id,
        input: retry_outcome.proposal.values,
        human_confirmed: true
      )
      assert retry_accepted.accepted?, retry_accepted.code
      assert_equal "succeeded", dispatcher.run(retry_accepted.job_ref).status
      assert_equal 10, third.reload.points
      assert_equal 10, @customer.reload.points
    end
  end
end
