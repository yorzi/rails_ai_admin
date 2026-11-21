# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# RailsAiAdmin::Assistant::Evaluation: a host's own questions through the
# real coordinator and tools, checked without a grader model here.
class AssistantEvaluationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  Evaluation = RailsAiAdmin::Assistant::Evaluation

  def setup
    reset_database
    reset_assistant
  end

  def cases
    [
      { name: "count", inputs: "How many customers are there?", metadata: { tools: %w[count_records], answer_includes: [ "1 customer" ] } },
      { name: "wrong-answer", inputs: "How many customers again?", metadata: { answer_includes: [ "42" ] } },
      { name: "forbidden-tool", inputs: "Find Alice", metadata: { tools_absent: %w[search_records] } }
    ]
  end

  def test_each_case_is_a_new_archived_conversation_checked_against_its_metadata
    with_assistant do
      LLMFixture.tool("count_records", { resource: "contract_customers" })
      LLMFixture.reply("There is 1 customer.")
      LLMFixture.reply("There is 1 customer.")
      LLMFixture.tool("search_records", { resource: "contract_customers", query: "Alice" })
      LLMFixture.reply("Alice is customer 1.")
      report = Evaluation.for(context, dataset: cases).run
      assert_equal %i[passed failed failed], report.trials.map(&:status)
      assert_equal %w[count_records], report.trials.first.result.tools
      assert_equal "There is 1 customer.", report.trials.first.evidence, "a grader sees the answer text"
      lines = Evaluation.summary(report)
      assert_equal "PASSED     count [count_records]", lines[0]
      assert_match(/\AFAILED     wrong-answer - The answer does not contain "42"/, lines[1])
      assert_match(/\AFAILED     forbidden-tool \[search_records\] - search_records was called/, lines[2])
      assert_equal "1 of 3 passed.", lines[3]
      refute report.passed?
      chats = RailsAiAdmin::Assistant::Chat.order(:id)
      assert_equal [ "archived" ] * 3, chats.map(&:status), "evaluation conversations leave the person's list"
      assert_equal [ context.actor_ref ], chats.map(&:actor_ref).uniq
      assert_equal 0, LLMFixture.pending
    end
  end

  def test_a_provider_failure_fails_the_case_and_cancels_the_retry
    with_assistant do
      LLMFixture.failure(500)
      report = Evaluation.for(context, dataset: [ { name: "down", inputs: "Hello" } ], grader: false).run
      trial = report.trials.first
      assert_equal :failed, trial.status
      assert_match(/ended as queued \(PROVIDER_UNAVAILABLE\)/, trial.assertion_failure.message)
      turn = RailsAiAdmin::Assistant::Turn.last
      assert_equal [ "cancelled", "CANCELLED" ], [ turn.status, turn.error_code ]
    end
  end

  def test_graders_and_dataset_rules
    with_assistant do
      graded = [ { name: "a", inputs: "Q?", expected_output: "A." }, { name: "b", inputs: "R?", expected_output: "B." } ]
      evaluator = Evaluation.for(context, dataset: graded).evaluator
      assert_includes evaluator.description.to_s, "gpt-4.1-mini"
      assert_includes Evaluation.for(context, dataset: graded, grader: "gpt-4.1-nano").evaluator.description.to_s, "gpt-4.1-nano"
      assert_equal false, Evaluation.for(context, dataset: graded, grader: false).evaluator
      assert_equal false, Evaluation.for(context, dataset: cases).evaluator, "no expected_output means checks only"
      error = assert_raises(RailsAiAdmin::ConfigurationError) { Evaluation.for(context, dataset: graded + cases) }
      assert_match(/every case an expected_output, or none/, error.message)
      Evaluation.for(context, dataset: graded + cases, grader: false)
      [ { name: "x", inputs: { q: 1 } }, { name: "x", inputs: " " }, { name: "x", inputs: "Q", metadata: { tool: [ "a" ] } },
        { name: "x", inputs: "Q", metadata: { tools: "count_records" } } ].each do |row|
        assert_raises(RailsAiAdmin::ConfigurationError, row.inspect) { Evaluation.for(context, dataset: [ row ]) }
      end
      assert_raises(RailsAiAdmin::ConfigurationError) { Evaluation.for(:someone, dataset: cases) }
      TestAssistant.available = false
      assert_raises(RailsAiAdmin::ConfigurationError) { Evaluation.for(context, dataset: cases) }
    end
  end

  def run_task(env)
    require "rake"
    application = Rake.application
    rake = Rake::Application.new
    Rake.application = rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/rails_ai_admin.rake", __dir__)
    previous = env.keys.to_h { |key| [ key, ENV[key] ] }
    env.each { |key, value| ENV[key] = value }
    status = nil
    out, err = capture_io do
      rake["rails_ai_admin:assistant:eval"].invoke
      status = 0
    rescue SystemExit => exit
      status = exit.status
    end
    [ status, out + err ]
  ensure
    previous&.each { |key, value| ENV[key] = value }
    Rake.application = application if application
  end

  def test_the_rake_task_checks_its_arguments_and_exits_with_the_result
    Dir.mktmpdir("raa-eval-", File.expand_path("../../tmp", __dir__)) do |directory|
      path = File.join(directory, "assistant_eval.yml")
      File.write(path, { "cases" => [ { "name" => "count", "inputs" => "How many customers?", "metadata" => { "tools" => [ "count_records" ] } } ] }.to_yaml)
      with_assistant do
        Rails.stub(:root, Pathname.new(directory)) do
          status, output = run_task("ACTOR" => "", "TENANT" => "")
          assert_equal [ 1, true ], [ status, output.include?("Usage: bin/rails rails_ai_admin:assistant:eval ACTOR=") ]
          status, output = run_task("ACTOR" => "raa:actor:Nobody:1", "TENANT" => context.tenant_ref, "FILE" => "assistant_eval.yml")
          assert_equal [ 1, true ], [ status, output.include?("is not a current admin person") ]
          LLMFixture.tool("count_records", { resource: "contract_customers" })
          LLMFixture.reply("There is 1 customer.")
          status, output = run_task("ACTOR" => context.actor_ref, "TENANT" => context.tenant_ref, "FILE" => "assistant_eval.yml")
          assert_equal 0, status, output
          assert_includes output, "PASSED     count [count_records]\n1 of 1 passed."
          LLMFixture.reply("I will not count.")
          status, output = run_task("ACTOR" => context.actor_ref, "TENANT" => context.tenant_ref, "FILE" => "assistant_eval.yml")
          assert_equal 1, status
          assert_includes output, "count_records was not called"
        end
      end
    end
  end

  def test_the_rake_task_resolves_the_person_and_reads_a_yaml_file
    Dir.mktmpdir("raa-eval-", File.expand_path("../../tmp", __dir__)) do |directory|
      path = File.join(directory, "assistant_eval.yml")
      File.write(path, { "cases" => [ { "name" => "count", "inputs" => "How many customers?", "metadata" => { "tools" => [ "count_records" ] } } ] }.to_yaml)
      with_assistant do
        LLMFixture.tool("count_records", { resource: "contract_customers" })
        LLMFixture.reply("There is 1 customer.")
        person = OperationJobContext.new.resolve_job(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, security_version: nil)
        assert_equal "PASSED     count [count_records]", Evaluation.summary(Evaluation.for(person, dataset: path).run).first
      end
    end
  end
end
