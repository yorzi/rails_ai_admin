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

  def systems(request) = request["messages"].select { |message| INSTRUCTION_ROLES.include?(message["role"]) }.map { |message| message["content"].to_s }

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
  end
end
