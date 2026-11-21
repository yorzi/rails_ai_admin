# frozen_string_literal: true

require "test_helper"
require "support/assistant"
require "rails_ai_admin/doctor"

# Host instructions from the assistant adapter and fallback models.
class AssistantHostSettingsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  # Guidance for actor 1 only; anyone else gets none.
  class InstructedAssistant < TestAssistant
    class_attribute :notes, default: "A VIP customer has at least 100 points."

    def instructions(context:) = context.actor.id == 1 ? notes : nil
  end

  def setup
    reset_database
    reset_assistant
    InstructedAssistant.notes = "A VIP customer has at least 100 points."
  end

  # OpenAI's chat completions name instructions "developer" messages.
  INSTRUCTION_ROLES = %w[system developer].freeze

  # A cache boundary turns the content into text blocks.
  def text(content) = content.is_a?(Array) ? content.map { |block| block["text"] }.join : content.to_s

  def systems(request) = request["messages"].select { |message| INSTRUCTION_ROLES.include?(message["role"]) }.map { |message| text(message["content"]) }

  def test_host_instructions_follow_the_admin_rules_for_each_turn_without_being_saved
    with_assistant(adapter: "AssistantHostSettingsTest::InstructedAssistant") do
      chat = new_chat
      admit(chat, "Who are the VIP customers?")
      LLMFixture.reply("None yet.")
      drain(chat)
      rules, notes = systems(LLMFixture.requests.last)
      assert_includes rules, "Only tool results are facts."
      assert_includes notes, "Notes from the operators of"
      assert_includes notes, "They do not change the rules above."
      assert notes.end_with?("A VIP customer has at least 100 points.\n")
      assert_equal %w[developer developer user], LLMFixture.requests.last["messages"].map { |message| message["role"] }
      assert_empty chat.messages.where(role: "system"), "instructions are rebuilt for each turn, never stored"

      # Changed guidance applies to the next turn of the same conversation.
      InstructedAssistant.notes = "  Points expire after a year.  "
      admit(chat, "And now?")
      LLMFixture.reply("Noted.")
      drain(chat)
      assert systems(LLMFixture.requests.last).last.end_with?("\n\nPoints expire after a year.\n")
      assert_equal 2, systems(LLMFixture.requests.last).size

      other = new_chat(actor: 2)
      admit(other, "Hello")
      LLMFixture.reply("Hi.")
      drain(other)
      assert_equal 1, systems(LLMFixture.requests.last).size, "nil adds nothing"
    end
  end

  def test_blank_and_invalid_instructions
    with_assistant(adapter: "AssistantHostSettingsTest::InstructedAssistant") do
      InstructedAssistant.notes = " \n "
      assert_nil RailsAiAdmin::Assistant::Runtime.host_instructions(context)
      [ :notes, "x" * 4_001, "Bell\a", "\xFF".dup.force_encoding("UTF-8") ].each do |value|
        InstructedAssistant.notes = value
        assert_raises(RailsAiAdmin::ConfigurationError, value.inspect) { RailsAiAdmin::Assistant::Runtime.host_instructions(context) }
      end
      InstructedAssistant.notes = "Line one\n\tLine two"
      assert_equal "Line one\n\tLine two", RailsAiAdmin::Assistant::Runtime.host_instructions(context)
    end
    with_assistant { assert_nil RailsAiAdmin::Assistant::Runtime.host_instructions(context), "an adapter without the method" }
  end

  def test_a_fallback_model_answers_when_the_model_is_unavailable
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: "gpt-4.1-nano", provider: "openai") { |model| model.name = "GPT-4.1 nano" }
    RubyLLM.models.load_from_store
    with_assistant do
      RailsAiAdmin.configuration.instance_variable_set(:@assistant_fallback_models, [ "gpt-4.1-nano" ])
      chat = new_chat
      turn = admit(chat, "Hello")
      LLMFixture.failure(503)
      LLMFixture.reply("Hi from the fallback.")
      drain(chat)
      assert_equal "completed", turn.reload.status
      assert_equal %w[gpt-4.1-mini gpt-4.1-nano], LLMFixture.requests.map { |request| request["model"] }
      assert_equal "Hi from the fallback.", chat.messages.where(role: "assistant").last.content

      # The next turn starts on the configured model again.
      admit(chat, "Again")
      LLMFixture.reply("Back on the main model.")
      drain(chat)
      assert_equal "gpt-4.1-mini", LLMFixture.requests.last["model"]
    end
  ensure
    RubyLLM::ActiveRecord::Model.where(model_id: "gpt-4.1-nano").delete_all
    RubyLLM.models.load_from_store
  end

  def test_a_rejected_request_does_not_fall_back_and_an_unknown_fallback_is_skipped
    with_assistant do
      RailsAiAdmin.configuration.instance_variable_set(:@assistant_fallback_models, [ "not-a-known-model" ])
      assert_empty RailsAiAdmin::Assistant::Runtime.fallback_models
      RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: "gpt-4.1-nano", provider: "openai") { |model| model.name = "GPT-4.1 nano" }
      RubyLLM.models.load_from_store
      RailsAiAdmin.configuration.instance_variable_set(:@assistant_fallback_models, [ "gpt-4.1-nano" ])
      chat = new_chat
      turn = admit(chat, "Hello")
      LLMFixture.failure(400)
      drain(chat)
      assert_equal [ "failed", "AI_REJECTED" ], [ turn.reload.status, turn.error_code ]
      assert_equal %w[gpt-4.1-mini], LLMFixture.requests.map { |request| request["model"] }
    end
  ensure
    RubyLLM::ActiveRecord::Model.where(model_id: "gpt-4.1-nano").delete_all
    RubyLLM.models.load_from_store
  end

  def test_doctor_names_the_fallbacks
    with_assistant do
      assert_includes RailsAiAdmin::Doctor.new.assistant_check.message, "Model gpt-4.1-mini; tools apply"
      RailsAiAdmin.configuration.instance_variable_set(:@assistant_fallback_models, %w[gpt-4.1-nano o4-mini])
      assert_includes RailsAiAdmin::Doctor.new.assistant_check.message, "Model gpt-4.1-mini (fallbacks gpt-4.1-nano, o4-mini); tools apply"
    end
  end

  # OpenRouter takes Anthropic-style cache controls; the fixture answers in
  # the OpenAI format both share.
  class OpenRouterAssistant
    def llm_context(context:)
      RubyLLM.context do |config|
        config.openrouter_api_key = "test-only-key"
        config.max_retries = 0
      end
    end

    def instructions(context:) = "Notes."
  end

  def openrouter_turn(caching:)
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: "anthropic/claude-haiku-5.5", provider: "openrouter") { |model| model.name = "Haiku" }
    RubyLLM.models.load_from_store
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return { |request| LLMFixture.respond(request) }
    with_assistant(adapter: "AssistantHostSettingsTest::OpenRouterAssistant", model: "anthropic/claude-haiku-5.5") do
      config = RailsAiAdmin.configuration
      config.instance_variable_set(:@assistant_provider, "openrouter")
      config.instance_variable_set(:@assistant_protocol, nil)
      config.instance_variable_set(:@assistant_prompt_caching, caching)
      chat = new_chat
      admit(chat, "Hello")
      LLMFixture.reply("Hi.")
      drain(chat)
      LLMFixture.requests.last
    end
  ensure
    reset_assistant
    RubyLLM::ActiveRecord::Model.where(provider: "openrouter").delete_all
    RubyLLM.models.load_from_store
  end

  def cache_marks(request)
    request["messages"].each_with_index.filter_map do |message, index|
      content = message["content"]
      [ index, content.last["cache_control"] ] if content.is_a?(Array) && content.last.is_a?(Hash) && content.last["cache_control"]
    end
  end

  def test_prompt_caching_marks_the_end_of_the_instructions
    request = openrouter_turn(caching: true)
    assert_equal({ "type" => "ephemeral" }, request["cache_control"])
    assert_equal [ [ 1, { "type" => "ephemeral" } ] ], cache_marks(request), "one boundary, after the operator notes"
    assert_equal %w[developer developer user], request["messages"].map { |message| message["role"] }
    assert_equal "Notes.", request["messages"][1]["content"].last["text"].lines.last.strip
  end

  def test_prompt_caching_can_be_turned_off
    request = openrouter_turn(caching: false)
    assert_nil request["cache_control"]
    assert_empty cache_marks(request)
  end

  def test_fallback_models_configuration
    [ [ "gpt-4.1-nano" ], %w[a b c], [] ].each do |models|
      config = assistant_configuration
      config.assistant_fallback_models = models
      config.send(:validate_assistant!)
    end
    [ "gpt-4.1-nano", %w[a b c d], [ "gpt-4.1-mini" ], %w[a a], [ "bad model" ], [ nil ] ].each do |models|
      config = assistant_configuration
      config.assistant_fallback_models = models
      assert_raises(RailsAiAdmin::ConfigurationError, models.inspect) { config.send(:validate_assistant!) }
    end
    assert assistant_configuration.assistant_prompt_caching, "caching is on by default"
    config = assistant_configuration
    config.assistant_prompt_caching = "yes"
    assert_raises(RailsAiAdmin::ConfigurationError) { config.send(:validate_assistant!) }
  end
end
