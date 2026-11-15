# frozen_string_literal: true

module RailsAiAdmin
  module Assistant
    # One actor's assistant spend in one tenant over the last 24 hours, read
    # from RubyLLM's usage ledger: every provider attempt that actor's admin
    # chats made, including retries and failed requests. The limits are
    # checked when a human message is admitted and again before each provider
    # request of a turn, so the request that crosses a limit still finishes.
    module Budget
      WINDOW = 24.hours
      TOKEN_COLUMNS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens].freeze

      # tokens sums every token bucket; cost is the known US dollar total and
      # unpriced counts attempts whose cost the provider and the model
      # registry could not price, so cost can be lower than the real spend.
      Spend = ::Data.define(:tokens, :cost, :requests, :unpriced, :token_limit, :cost_limit) do
        def limited? = !token_limit.nil? || !cost_limit.nil?
        def tokens_exceeded? = !token_limit.nil? && tokens >= token_limit
        def cost_exceeded? = !cost_limit.nil? && cost >= cost_limit
        def exceeded? = tokens_exceeded? || cost_exceeded?
      end

      module_function

      def limited?
        config = RailsAiAdmin.configuration
        !config.assistant_daily_token_limit.nil? || !config.assistant_daily_cost_limit.nil?
      end

      # True only when a configured limit is reached; never queries without one.
      def exceeded?(chat)
        limited? && spend(actor_ref: chat.actor_ref, tenant_ref: chat.tenant_ref).exceeded?
      end

      def spend(actor_ref:, tenant_ref:, now: Time.current)
        config = RailsAiAdmin.configuration
        usages = usages(actor_ref: actor_ref, tenant_ref: tenant_ref, since: now - WINDOW)
        table = usages.arel_table
        *buckets, requests = usages.pick(*TOKEN_COLUMNS.map { |column| table[column].sum }, table[:id].count)
        cost = requests.to_i.zero? ? BigDecimal("0") : BigDecimal(usages.sum(:total_cost).to_s)
        unpriced = requests.to_i.zero? ? 0 : usages.where(total_cost: nil).count
        Spend.new(tokens: buckets.sum(&:to_i), cost: cost, requests: requests.to_i, unpriced: unpriced,
          token_limit: config.assistant_daily_token_limit, cost_limit: config.assistant_daily_cost_limit)
      end

      # Usage rows owned by the actor's admin chats. RubyLLM keeps the owner
      # when a chat is deleted, so pruning never runs inside the window.
      def usages(actor_ref:, tenant_ref:, since:)
        chats = Chat.where(actor_ref: actor_ref, tenant_ref: tenant_ref).select(:id)
        usage = ::RubyLLM::ActiveRecord::Usage
        usage.where(owner_type: Chat.polymorphic_name, owner_id: chats).where(usage.arel_table[:created_at].gt(since))
      end
    end
  end
end
