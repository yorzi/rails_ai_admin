# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# The conversation page shows spend against configured limits and keeps a
# refused message's text.
class AssistantBudgetIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  def setup
    reset_database
    reset_assistant
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def start_chat(**params)
    post "/backoffice/assistant/conversations", params: params
    RailsAiAdmin::Assistant::Chat.for_owner(context).order(:id).last
  end

  def spend!(chat, cost:, tokens:)
    RubyLLM::ActiveRecord::Usage.create!(chat: chat, owner: chat, operation: "chat", provider: "openai", model: "gpt-4.1-mini",
      status: "succeeded", input_tokens: tokens, total_cost: cost)
  end

  def test_spend_line_appears_only_with_a_limit_and_a_refused_message_keeps_its_text
    with_assistant do
      chat = start_chat
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-chat-budget", count: 0
      RailsAiAdmin.configuration.assistant_daily_token_limit = 2_000
      RailsAiAdmin.configuration.assistant_daily_cost_limit = BigDecimal("1")
      spend!(chat, cost: BigDecimal("0.0123"), tokens: 1_200)
      spend!(chat, cost: nil, tokens: 300)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-chat-budget:not(.raa-chat-budget-reached)",
        text: "Assistant use in the last 24 hours: 1,500 of 2,000 tokens · US$0.0123 of US$1.00. " \
          "The cost of 1 request is not known, so the real cost can be higher."
      # The polled transcript frame carries it, so it updates after each reply.
      get "/backoffice/assistant/conversations/#{chat.ref}", headers: { "Turbo-Frame" => "raa_assistant_transcript" }
      assert_select "turbo-frame#raa_assistant_transcript .raa-chat-budget", text: /1,500 of 2,000 tokens/
      get "/backoffice/assistant/conversations/#{chat.ref}"
      # Cached reads count toward the limit and are named.
      RubyLLM::ActiveRecord::Usage.create!(chat: chat, owner: chat, operation: "chat", provider: "anthropic", model: "claude-haiku-5-5",
        status: "succeeded", input_tokens: 0, cache_read_tokens: 1_000, total_cost: BigDecimal("0"))
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-chat-budget", text: /2,500 of 2,000 tokens \(1,000 read from the prompt cache\) · /
      RubyLLM::ActiveRecord::Usage.where(cache_read_tokens: 1_000).delete_all

      spend!(chat, cost: BigDecimal("1.5"), tokens: 10)
      key = css_select("input[name=admission_key]").first["value"]
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "Count the customers", admission_key: key }
      assert_response :too_many_requests
      assert_select "#raa-chat-error", text: /reached this administration's assistant spending limit/
      assert_select "textarea[name=content]", text: "Count the customers"
      assert_select "input[name=admission_key][value=?]", key
      assert_select ".raa-chat-budget.raa-chat-budget-reached", text: /US\$1\.51 of US\$1\.00/
      assert_equal 0, chat.turns.count
    end
  end

  def test_a_question_from_a_page_over_the_limit_opens_the_conversation_with_the_text
    with_assistant do
      RailsAiAdmin.configuration.assistant_daily_token_limit = 10
      spend!(start_chat, cost: nil, tokens: 10)
      post "/backoffice/assistant/conversations", params: { content: "Who changed this?", about: { resource: "contract_customers", id: @customer.id.to_s } }
      assert_response :too_many_requests
      assert_select "#raa-chat-error", text: /spending limit/
      assert_select "textarea[name=content]", text: "Who changed this?"
      assert_equal 0, RailsAiAdmin::Assistant::Turn.count
    end
  end

  def test_a_turn_stopped_by_the_limit_explains_itself_without_try_again
    with_assistant do
      RailsAiAdmin.configuration.assistant_daily_token_limit = 16
      chat = start_chat
      admit(chat, "How many customers?")
      LLMFixture.tool("count_records", { resource: "contract_customers" })
      drain(chat)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "body", text: /reached the assistant spending limit for the last 24 hours/
      assert_select "form[action$='/retry']", count: 0
    end
  end
end
