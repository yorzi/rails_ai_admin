# frozen_string_literal: true

module RailsAiAdmin
  # Deletes bookkeeping rows that can no longer be used (RAA-005): proposed
  # intents and fixed selections whose expiry passed more than older_than ago.
  # It never touches a run that started, succeeded or belongs to a collection,
  # anything still referenced by work, batch or child rows, or audit events
  # (their retention is the host's decision, see ADR 0005).
  class Prune
    DEFAULT_AGE = 7.days
    BATCH = 1000
    Result = Data.define(:intents, :selections, :import_drafts)

    def initialize(older_than: DEFAULT_AGE, now: Time.current)
      unless older_than.is_a?(ActiveSupport::Duration) || older_than.is_a?(Numeric)
        raise ConfigurationError, "older_than must be a duration"
      end
      raise ConfigurationError, "older_than must not be negative" if older_than.to_i.negative?
      @now, @cutoff = now, now - older_than
    end

    def call
      drafts = if ImportDraft.table_exists?
        ImportDraft.where("expires_at <= ?", @now).in_batches(of: BATCH).delete_all
      end
      Result.new(prune_intents, prune_selections, drafts || 0)
    end

    private

    def prune_intents
      runs = OperationRun.arel_table
      candidates = OperationRun.where(status: "proposed", parent_run_id: nil, approved_digest: nil, confirmed_at: nil)
        .where(runs[:expires_at].lt(@cutoff))
        .where.not(id: WorkItem.select(:operation_run_id))
        .where.not(id: BatchItem.select(:operation_run_id))
        .where.not(id: BatchItem.select(:parent_run_id))
        .where.not(id: OperationRun.where.not(parent_run_id: nil).select(:parent_run_id))
      # Re-assert the safety predicates inside DELETE so a concurrent resume or
      # execution cannot have its committed receipt removed.
      delete_in_batches(candidates) do |ids|
        OperationRun.where(id: ids, status: "proposed", parent_run_id: nil, approved_digest: nil, confirmed_at: nil)
          .where(runs[:expires_at].lt(@cutoff)).delete_all
      end
    end

    def prune_selections
      selections = Selection.arel_table
      candidates = Selection.where(selections[:expires_at].lt(@cutoff))
        .where.not(id: OperationRun.where.not(selection_id: nil).select(:selection_id))
      delete_in_batches(candidates) do |ids|
        Selection.transaction do
          locked = Selection.lock.where(id: ids).where(selections[:expires_at].lt(@cutoff))
            .where.not(id: OperationRun.where.not(selection_id: nil).select(:selection_id)).pluck(:id)
          next 0 if locked.empty?
          SelectionItem.where(selection_id: locked).delete_all
          Selection.where(id: locked).delete_all
        end
      rescue ActiveRecord::InvalidForeignKey
        0
      end
    end

    def delete_in_batches(relation)
      total = 0
      loop do
        ids = relation.limit(BATCH).pluck(:id)
        break if ids.empty?
        total += yield(ids)
        break if ids.size < BATCH
      end
      total
    end
  end
end
