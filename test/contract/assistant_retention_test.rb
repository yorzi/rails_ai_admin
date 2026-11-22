# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# config.assistant_retention and rails_ai_admin:assistant:prune.
class AssistantRetentionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  Retention = RailsAiAdmin::Assistant::Retention

  def setup
    reset_database
    reset_assistant
  end

  def answered_chat(actor: 1)
    chat = new_chat(actor: actor)
    admit(chat, "How many customers?")
    LLMFixture.tool("count_records", { resource: "contract_customers" })
    LLMFixture.reply("There are 2.")
    drain(chat)
    chat
  end

  def test_deletes_quiet_conversations_with_their_messages_and_keeps_the_spend_ledger
    with_assistant do
      old = travel_to(100.days.ago) { answered_chat }
      recent = answered_chat
      old_ids = old.messages.pluck(:id)
      assert_equal 2, RubyLLM::ActiveRecord::Usage.where(owner: old).count
      calls = RubyLLM::ActiveRecord::ToolCall.where(message_type: RailsAiAdmin::Assistant::Message.polymorphic_name, message_id: old_ids)
      assert_equal 1, calls.count
      product = ProductChat.create!(model: "gpt-4.1-mini", provider: "openai", updated_at: 1.year.ago)

      assert_equal 1, Retention.new(older_than: 90.days).call.chats
      refute RailsAiAdmin::Assistant::Chat.exists?(old.id)
      assert_equal 0, RailsAiAdmin::Assistant::Message.where(id: old_ids).count
      assert_equal 0, RailsAiAdmin::Assistant::Turn.where(chat_id: old.id).count
      assert_equal 0, calls.count
      kept = RubyLLM::ActiveRecord::Usage.where(owner_type: RailsAiAdmin::Assistant::Chat.polymorphic_name, owner_id: old.id)
      assert_equal 2, kept.count, "the usage ledger keeps what was spent"
      assert kept.all? { |usage| usage.chat_id.nil? && usage.message_id.nil? && usage.input_tokens == 12 }
      assert RailsAiAdmin::Assistant::Chat.exists?(recent.id)
      assert_equal 4, recent.messages.where.not(role: "system").count
      assert ProductChat.exists?(product.id), "host product chats are never touched"
      assert_equal 0, Retention.new(older_than: 90.days).call.chats
    end
  end

  def test_keeps_conversations_with_active_turns_or_usage_inside_the_budget_window
    with_assistant do
      waiting = new_chat
      admit(waiting, "Still queued")
      waiting.update_columns(updated_at: 30.days.ago)
      # A chat whose last message is old but whose spend is still counted today.
      spending = new_chat
      RubyLLM::ActiveRecord::Usage.create!(chat: spending, owner: spending, operation: "chat", provider: "openai",
        model: "gpt-4.1-mini", status: "succeeded", input_tokens: 5)
      spending.update_columns(updated_at: 30.days.ago)
      archived = new_chat
      archived.update_columns(status: "archived", updated_at: 30.days.ago)

      assert_equal 1, Retention.new(older_than: 1.day).call.chats
      assert RailsAiAdmin::Assistant::Chat.exists?(waiting.id)
      assert RailsAiAdmin::Assistant::Chat.exists?(spending.id)
      refute RailsAiAdmin::Assistant::Chat.exists?(archived.id)
      travel 25.hours do
        assert_equal 1, Retention.new(older_than: 1.day).call.chats
        refute RailsAiAdmin::Assistant::Chat.exists?(spending.id)
      end
    end
  end

  def test_requires_a_configured_duration_of_at_least_a_day
    with_assistant do
      assert_raises(RailsAiAdmin::ConfigurationError) { Retention.new }
      assert_raises(RailsAiAdmin::ConfigurationError) { Retention.new(older_than: 12.hours) }
      assert_raises(RailsAiAdmin::ConfigurationError) { Retention.new(older_than: 86_400) }
      RailsAiAdmin.configuration.assistant_retention = 30.days
      assert_equal 0, Retention.new.call.chats
    end
  end

  def test_null_usage_owner_does_not_halt_retention_and_old_mcp_tokens_are_pruned
    with_assistant do
      old = travel_to(40.days.ago) { answered_chat }
      RubyLLM::ActiveRecord::Usage.create!(owner_type: RailsAiAdmin::Assistant::Chat.polymorphic_name, owner_id: nil,
        operation: "chat", provider: "openai", model: "gpt-4.1-mini", status: "succeeded", input_tokens: 1)
      require "rails_ai_admin/mcp"
      expired_token, = RailsAiAdmin::Mcp::AccessToken.issue!(context, name: "Old token", lifetime: "30")
      expired_token.update_columns(expires_at: 40.days.ago)
      active_token, = RailsAiAdmin::Mcp::AccessToken.issue!(context, name: "Active token", lifetime: "30")

      assert_equal 1, Retention.new(older_than: 30.days).call.chats
      refute RailsAiAdmin::Assistant::Chat.exists?(old.id)
      refute RailsAiAdmin::Mcp::AccessToken.exists?(expired_token.id)
      assert RailsAiAdmin::Mcp::AccessToken.exists?(active_token.id)
    end
  end
end
