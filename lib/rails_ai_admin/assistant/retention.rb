# frozen_string_literal: true

module RailsAiAdmin
  module Assistant
    # Deletes conversations that received no message for older_than
    # (config.assistant_retention): the chat, its turns, messages, tool calls,
    # queued messages and chat files. RubyLLM's usage ledger rows are kept,
    # without the chat and message ids, as the record of what was spent. A chat
    # with an active turn, or with usage inside the budget window, is kept so
    # a running turn and the current day's spend are never lost. Review
    # Surfaces belong to rails_tool_views and follow its own purge lifecycle.
    class Retention
      BATCH = 100
      Result = ::Data.define(:chats)

      def initialize(older_than: RailsAiAdmin.configuration.assistant_retention, now: Time.current)
        raise ConfigurationError, "Set config.assistant_retention to prune conversations" if older_than.nil?
        unless older_than.is_a?(ActiveSupport::Duration) && older_than >= 1.day
          raise ConfigurationError, "older_than must be a duration of at least one day"
        end
        @now = now
        @cutoff = now - older_than
      end

      def call
        deleted = 0
        last_id = nil
        loop do
          batch = candidates
          batch = batch.where(Chat.arel_table[:id].gt(last_id)) if last_id
          ids = batch.order(:id).limit(BATCH).pluck(:id)
          break if ids.empty?
          ids.each { |id| deleted += 1 if delete(id) }
          last_id = ids.last
          break if ids.size < BATCH
        end
        Result.new(deleted)
      end

      private

      def candidates
        Chat.where(Chat.arel_table[:updated_at].lt(@cutoff))
          .where.not(id: Turn.where(status: Turn::ACTIVE).select(:chat_id))
          .where.not(id: recent_usage_owners)
      end

      def recent_usage_owners
        usage = ::RubyLLM::ActiveRecord::Usage
        usage.where(owner_type: Chat.polymorphic_name).where(usage.arel_table[:created_at].gt(@now - Budget::WINDOW)).select(:owner_id)
      end

      # Rechecked under the chat lock that admission and claiming also take,
      # so a message admitted meanwhile keeps its conversation.
      def delete(id)
        Chat.transaction do
          chat = Chat.lock.find_by(id: id)
          next false unless chat && candidates.exists?(id: chat.id)
          chat.destroy!
          true
        end
      end
    end
  end
end
