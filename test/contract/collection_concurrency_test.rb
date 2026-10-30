# frozen_string_literal: true

require "test_helper"
require "support/collections"
require "timeout"

class CollectionConcurrencyTest < Minitest::Test
  include DatabaseHelpers
  include CollectionContractHelpers
  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Second")
  end

  def race(*actions)
    ready, start = Queue.new, Queue.new
    workers = actions.map do |action|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          action.call
        end
      rescue StandardError => error
        error
      end
    end
    Timeout.timeout(10) do
      workers.size.times { ready.pop }
      workers.size.times { start << true }
      workers.map(&:value)
    end
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end

  def test_concurrent_admission_creates_one_run_and_one_fixed_child_set
    with_collection do
      proposed = proposal
      action = -> { admit(proposed) }
      results = race(action, action)
      assert results.all? { |result| result.is_a?(RailsAiAdmin::Collections::Result) }, results.inspect
      assert results.any?(&:accepted?)
      assert results.all? { |result| result.accepted? || result.code == "CONFLICT" }
      assert_equal [ proposed.intent.id ], results.filter_map(&:job_ref).uniq
      assert_equal 2, RailsAiAdmin::BatchItem.count
      assert_equal 2, RailsAiAdmin::OperationRun.where(parent_run_id: proposed.intent.id).count
      assert_equal 1, RailsAiAdmin::AuditEvent.where(correlation_ref: proposed.intent.id, status: "admitted").count
      assert_equal 0, @customer.reload.points
    end
  end

  def test_cancel_and_admission_serialize_without_a_second_or_resurrected_run
    with_collection do
      proposed = proposal
      cancel = -> { RailsAiAdmin::Collections::Runner.new.cancel(context: context, job_ref: proposed.intent.id) }
      results = race(-> { admit(proposed) }, cancel)
      assert results.all? { |result| result.is_a?(RailsAiAdmin::Collections::Result) }, results.inspect
      cancel.call # A controlled SQLite write-conflict may require retrying cancel.
      parent = RailsAiAdmin::OperationRun.find(proposed.intent.id)
      assert_equal "cancelled", parent.status
      assert_includes [ 0, 2 ], RailsAiAdmin::BatchItem.count
      assert_empty RailsAiAdmin::BatchItem.where.not(status: "cancelled")
      child_count = RailsAiAdmin::BatchItem.count
      replay = admit(proposed)
      assert(parent.approved_digest ? replay.replayed && replay.job_ref == parent.id && replay.status == "cancelled" : replay.code == "CONFLICT", replay.inspect)
      assert_equal child_count, RailsAiAdmin::BatchItem.count
      assert_equal "cancelled", parent.reload.status
      assert_equal 0, @customer.reload.points
      assert_equal 1, RailsAiAdmin::AuditEvent.where(correlation_ref: parent.id, status: "cancelled").count
    end
  end

  def test_duplicate_worker_jobs_commit_each_target_once
    with_collection do
      accepted = admit
      CollectionContractOperation.hook = ->(_record) { sleep 0.01 }
      action = -> { RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref) }
      results = race(action, action)
      assert results.all? { |result| result.is_a?(RailsAiAdmin::Collections::Result) }, results.inspect
      RailsAiAdmin::Collections::Dispatcher.new.run(accepted.job_ref)
      assert_equal [ 8, 8 ], [ @customer.reload.points, @second.reload.points ]
      assert_equal [ 1, 1 ], [ @customer.lock_version, @second.lock_version ]
      assert_equal 2, RailsAiAdmin::BatchItem.where(status: "succeeded").count
      assert_equal 2, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end
end
