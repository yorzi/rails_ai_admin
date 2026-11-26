# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    module Budget
      class Exceeded < StandardError; end

      module_function

      # Only a bounded observation and the configured instructions go to the
      # provider. Its one structured decision can suppress a predeclared review.
      def review?(run, context, observation)
        raise ConfigurationError, "Model-assisted recipes require the assistant" unless RailsAiAdmin.configuration.assistant
        require_relative "../assistant"
        config = RailsAiAdmin.configuration
        llm = Assistant.llm_context(context)
        raise AccessDenied unless llm
        raise Exceeded if exceeded?(run.tenant_ref)
        chat = llm.chat(model: config.assistant_model, provider: config.assistant_provider, protocol: config.assistant_protocol&.to_sym)
        chat.with_owner(run).with_max_output_tokens(96).with_schema(type: "object", additionalProperties: false,
          required: [ "review" ], properties: { review: { type: "boolean" } })
        response = chat.ask(JSON.generate(instructions: run.definition.fetch("instructions"), observed_value: observation.count,
          decision: "Should a human review the configured operation?")).content
        response = JSON.parse(response) if response.is_a?(String) && response.bytesize <= 4096
        raise ConfigurationError, "Invalid recipe decision" unless response.is_a?(Hash) && [ true, false ].include?(response["review"])
        response["review"]
      end

      def exceeded?(tenant_ref)
        usage = ::RubyLLM::ActiveRecord::Usage
        owners = RecipeRun.where(tenant_ref: tenant_ref).select(:id)
        ledger = usage.where(owner_type: RecipeRun.polymorphic_name, owner_id: owners, created_at: 24.hours.ago..)
        return true if ledger.where(total_cost: nil).exists?
        totals = ledger.pick(*Assistant::Budget::TOKEN_COLUMNS.map { |name| usage.arel_table[name].sum })
        config = RailsAiAdmin.configuration
        Array(totals).sum(&:to_i) >= config.recipe_daily_token_limit || ledger.sum(:total_cost) >= config.recipe_daily_cost_limit
      end
    end
  end
end
