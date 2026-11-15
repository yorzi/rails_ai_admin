# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# Token and cost limits per actor and tenant over a rolling 24 hours, read from
# RubyLLM's usage ledger rows owned by that actor's admin chats.
class AssistantBudgetTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveSupport::Testing::TimeHelpers

  Budget = RailsAiAdmin::Assistant::Budget

  def setup
    reset_database
    reset_assistant
  end

  def usage(chat, cost: nil, tokens: 10, at: Time.current)
    RubyLLM::ActiveRecord::Usage.create!(chat: chat, owner: chat, operation: "chat", provider: "openai", model: "gpt-4.1-mini",
      status: "succeeded", input_tokens: tokens, output_tokens: 0, total_cost: cost, created_at: at, updated_at: at)
  end

  def spend(actor: 1, tenant: 1) = Budget.spend(actor_ref: context(actor: actor, tenant: tenant).actor_ref, tenant_ref: context(actor: actor, tenant: tenant).tenant_ref)

  def test_spend_sums_every_token_bucket_and_the_known_cost_of_the_actor_in_the_window
    with_assistant do
      RailsAiAdmin.configuration.assistant_daily_token_limit = 1_000
      chat = new_chat
      RubyLLM::ActiveRecord::Usage.create!(chat: chat, owner: chat, operation: "chat", provider: "openai", model: "gpt-4.1-mini", status: "failed",
        input_tokens: 1, output_tokens: 2, cache_read_tokens: 3, cache_write_tokens: 4, thinking_tokens: 5, total_cost: BigDecimal("0.0001"))
      usage(new_chat, cost: nil, tokens: 100)
      usage(chat, cost: BigDecimal("5"), tokens: 999, at: 25.hours.ago)
      usage(new_chat(actor: 2), cost: BigDecimal("7"), tokens: 999)
      # Host product chats share the ledger table and never count.
      product = ProductChat.create!(model: "gpt-4.1-mini", provider: "openai")
      RubyLLM::ActiveRecord::Usage.create!(chat: product, owner: product, operation: "chat", provider: "openai", model: "gpt-4.1-mini",
        status: "succeeded", input_tokens: 999, total_cost: 9)
      result = spend
      assert_equal [ 115, BigDecimal("0.0001"), 2, 1 ], [ result.tokens, result.cost, result.requests, result.unpriced ]
      assert_equal [ 1_000, nil ], [ result.token_limit, result.cost_limit ]
      refute result.exceeded?
      assert_equal 0, spend(tenant: 2).requests
    end
  end

  def test_limits_refuse_new_messages_but_never_a_continuation
    with_assistant do
      chat = new_chat
      usage(chat, cost: BigDecimal("0.40"), tokens: 500)
      assert admit(chat, "No limits configured")
      RailsAiAdmin.configuration.assistant_daily_cost_limit = BigDecimal("0.40")
      error = assert_raises(RailsAiAdmin::AccessDenied) { admit(chat, "Over the cost limit") }
      assert_equal "BUDGET_EXCEEDED", error.code
      continuation = RailsAiAdmin::Assistant::Coordinator.admit!(chat, kind: "continuation", content: "Review result", admission_key: "intent:#{SecureRandom.uuid}")
      assert_equal "queued", continuation.status
      RailsAiAdmin.configuration.assistant_daily_cost_limit = BigDecimal("1")
      RailsAiAdmin.configuration.assistant_daily_token_limit = 500
      assert_equal "BUDGET_EXCEEDED", assert_raises(RailsAiAdmin::AccessDenied) { admit(chat, "Over the token limit") }.code
      assert admit(new_chat(actor: 2), "Another actor has their own allowance")
      travel 25.hours do
        assert admit(chat, "A new window")
      end
      assert_empty LLMFixture.requests
    end
  end

  def test_a_turn_stops_before_the_provider_request_that_would_start_over_the_limit
    with_assistant do
      # Each fixture request reports 12 input and 4 output tokens.
      RailsAiAdmin.configuration.assistant_daily_token_limit = 16
      chat = new_chat
      admit(chat, "How many customers?")
      LLMFixture.tool("count_records", { resource: "contract_customers" })
      LLMFixture.reply("Never requested")
      drain(chat)
      turn = chat.turns.last
      assert_equal [ "failed", "BUDGET_EXCEEDED" ], [ turn.status, turn.error_code ]
      assert_equal 1, LLMFixture.requests.size
      assert_equal 1, LLMFixture.pending
      assert_equal 16, spend.tokens
      assert_equal 1, chat.messages.where(role: "tool").count, "the tool call that was already requested still ran"
    end
  end

  def test_a_continuation_over_the_limit_fails_without_a_provider_request
    with_assistant do
      chat = new_chat
      usage(chat, cost: BigDecimal("2"))
      RailsAiAdmin.configuration.assistant_daily_cost_limit = 1
      RailsAiAdmin::Assistant::Coordinator.admit!(chat, kind: "continuation", content: "Review result", admission_key: "intent:#{SecureRandom.uuid}")
      drain(chat)
      assert_equal [ "failed", "BUDGET_EXCEEDED" ], chat.turns.last.slice(:status, :error_code).values
      assert_empty LLMFixture.requests
    end
  end

  def test_configuration_validates_limits_and_retention
    config = assistant_configuration
    config.assistant_daily_token_limit = 0
    assert_raises(RailsAiAdmin::ConfigurationError) { config.finalize! }
    [ 0, -1, Float::INFINITY, "1", 2_000_000 ].each do |value|
      config = assistant_configuration
      config.assistant_daily_cost_limit = value
      assert_raises(RailsAiAdmin::ConfigurationError, value.inspect) { config.finalize! }
    end
    [ 12.hours, 11.years, 30 ].each do |value|
      config = assistant_configuration
      config.assistant_retention = value
      assert_raises(RailsAiAdmin::ConfigurationError, value.inspect) { config.finalize! }
    end
    config = assistant_configuration
    config.assistant_daily_token_limit = 200_000
    config.assistant_daily_cost_limit = 0.5
    config.assistant_retention = 90.days
    config.finalize!
    assert_equal BigDecimal("0.5"), config.assistant_daily_cost_limit
    assert config.assistant_daily_cost_limit.frozen?
  end
end
