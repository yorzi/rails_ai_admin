# frozen_string_literal: true

require "test_helper"
require "support/assistant_eval"

# Runs the assistant evaluation set (test/assistant_eval/questions.yml).
#
# Offline (default): each question's expected tool calls and reference answer
# are replayed through RubyLLM's real provider parser, tool loop and the admin
# tools, then graded. This proves the dataset, the expected answers and the
# tool semantics (a silently applied default scope or display-text values fail
# here). It does not measure a model.
#
# Live, before a release (see COMPATIBILITY.md): put the provider key in an env
# file, never on the command line, then run
#   set -a; . ./.env.eval; set +a
#   RAA_EVAL_LIVE=1 RAA_EVAL_MODEL=gpt-4.1-mini bundle exec ruby -Itest test/contract/assistant_eval_test.rb
# with OPENAI_API_KEY, or RAA_EVAL_PROVIDER=openrouter and OPENROUTER_API_KEY.
class AssistantEvalTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  LIVE = ENV["RAA_EVAL_LIVE"] == "1"

  # Provider context for live runs; the key comes only from the environment.
  class LiveAssistant
    def llm_context(context:)
      provider = ENV.fetch("RAA_EVAL_PROVIDER", "openai")
      RubyLLM.context do |config|
        config.public_send("#{provider}_api_key=", ENV.fetch("#{provider.upcase}_API_KEY"))
        config.request_timeout = 60
      end
    end
  end

  def setup
    reset_database
    reset_assistant
    Customer.delete_all
    if LIVE
      WebMock.allow_net_connect!
      RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: ENV.fetch("RAA_EVAL_MODEL"), provider: ENV.fetch("RAA_EVAL_PROVIDER", "openai")) { |model| model.name = ENV.fetch("RAA_EVAL_MODEL") }
    end
    @ids = AssistantEval.seed!
  end

  def teardown
    WebMock.disable_net_connect! if LIVE
  end

  def ask(question)
    options = { resources: AssistantEval::RESOURCES, policy: "AssistantEval::Policy" }
    options.merge!(adapter: "AssistantEvalTest::LiveAssistant", model: ENV.fetch("RAA_EVAL_MODEL")) if LIVE
    with_assistant(**options) do
      RailsAiAdmin.configuration.assistant_provider = ENV.fetch("RAA_EVAL_PROVIDER", "openai") if LIVE
      chat = new_chat
      unless LIVE
        question.fetch("script").each do |step|
          step.key?("tool") ? LLMFixture.tool(step["tool"], AssistantEval.interpolate(step["args"], @ids)) : LLMFixture.reply(step.fetch("reply"))
        end
      end
      before = AssistantEval.business_digest
      turn = admit(chat, question.fetch("question"))
      drain(chat)
      assert_equal "completed", turn.reload.status, "#{question['id']}: #{turn.error_code}"
      AssistantEval.grade(question, chat, before)
    end
  end

  def test_the_set_has_twenty_three_distinct_questions
    ids = AssistantEval.questions.map { |question| question.fetch("id") }
    assert_equal 23, ids.size
    assert_equal ids.uniq, ids
  end

  AssistantEval.questions.each do |question|
    define_method("test_eval_#{question.fetch('id').tr('-', '_')}") do
      failures = ask(question)
      assert_empty failures, "#{question['id']}: #{failures.join('; ')}"
      assert_equal 0, LLMFixture.pending unless LIVE
    end
  end
end
