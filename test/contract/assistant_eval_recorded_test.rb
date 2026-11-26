# frozen_string_literal: true

require "test_helper"
require "support/recorded_provider"

# The assistant evaluation set (test/assistant_eval/questions.yml) answered by
# a real model through OpenRouter, recorded once and replayed offline (see
# test/support/recorded_provider.rb). Each replay re-runs the admin tools and
# grades the recorded answers again. The grade must equal the one recorded in
# test/cassettes/openrouter/manifest.json, so a question the model missed is
# listed there with its reason instead of silently passing, and a change in a
# tool result that alters the grade fails here.
class AssistantEvalRecordedTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include RecordedProviderHelpers

  MODEL = RecordedProvider::PRIMARY

  def setup
    reset_database
    reset_assistant
    Customer.delete_all
    AssistantEval.seed!
  end

  def test_the_recorded_grades_cover_every_question
    skip "recording" if RecordedProvider::RECORD || RecordedProvider::REGRADE
    grades = RecordedProvider.manifest.dig("eval", MODEL)
    assert grades, "record the evaluation (test/support/recorded_provider.rb)"
    assert_equal AssistantEval.questions.map { |question| question.fetch("id") }.sort, grades.keys.sort
  end

  AssistantEval.questions.each do |question|
    id = question.fetch("id")
    define_method("test_recorded_eval_#{id.tr('-', '_')}") do
      with_recorded_assistant(model: MODEL) do
        AssistantEval.with_quality(question) do
          recorded("eval/#{id}", model: MODEL) do
            chat = new_chat
            before = AssistantEval.business_digest
            turn = admit(chat, question.fetch("question"))
            drain(chat)
            failures = turn.reload.status == "completed" ? AssistantEval.grade(question, chat, before) : [ "turn #{turn.status}: #{turn.error_code}" ]
            if RecordedProvider::RECORD || RecordedProvider::REGRADE
              RecordedProvider.note!("eval", MODEL, id, RecordedProvider.spend(chat).merge("failures" => failures))
            else
              recorded_failures = RecordedProvider.manifest.dig("eval", MODEL, id, "failures")
              assert_equal recorded_failures, failures, "#{id}: the grade differs from the recording"
            end
            # Safety holds whatever the model answered.
            assert_empty failures.grep(/exposed|business data changed/), "#{id}: #{failures.join('; ')}"
          end
        end
      end
    end
  end
end
