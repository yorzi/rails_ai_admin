# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Assistant
    # Questions a host asks its own admin before rollout, on RubyLLM's
    # evaluation runner. Each case is one new conversation for one person:
    # the question runs through the real coordinator, tools, grants, operator
    # notes and model, so a pass means this person's admin answered it.
    # Reviews the model proposes are never confirmed, so no record changes.
    #
    # A case's metadata may list tools that must or must not be called and
    # text the answer must contain. With an expected_output on every case, a
    # model also grades the answer's meaning through the host's own provider
    # context; without one on any case, only the checks run.
    #
    #   evaluation = RailsAiAdmin::Assistant::Evaluation.for(context, dataset: "config/rails_ai_admin/assistant_eval.yml")
    #   report = evaluation.run
    #   report.passed?
    class Evaluation < ::RubyLLM::Evaluation
      Answer = ::Data.define(:text, :tools, :status, :error_code, :chat_ref)
      CHECKS = %w[tools tools_absent answer_includes].freeze
      MAX_CASES = 200

      adapt(Answer) { |answer| answer.text }

      class << self
        attr_reader :context

        # A subclass bound to one person, one dataset and one grader. grader
        # is a model id, nil for the assistant's own model, or false to skip
        # model grading.
        def for(context, dataset:, grader: nil)
          raise ConfigurationError, "The evaluation needs an admin Context" unless context.is_a?(Context)
          cases = self.cases(dataset: dataset)
          raise ConfigurationError, "An assistant evaluation has at most #{MAX_CASES} cases" if cases.size > MAX_CASES
          cases.each { |test_case| check_case!(test_case) }
          graded = cases.count(&:expected_output?)
          if grader != false && graded.positive? && graded < cases.size
            raise ConfigurationError, "Give every case an expected_output, or none, or run without a grader"
          end
          llm = Assistant.llm_context(context)
          raise ConfigurationError, "The assistant is unavailable for this person (llm_context returned nil)" unless llm
          klass = Class.new(self)
          klass.instance_variable_set(:@context, context)
          klass.dataset(dataset)
          if grader == false || graded.zero?
            klass.evaluator(false)
          else
            model = grader || RailsAiAdmin.configuration.assistant_model
            klass.evaluator(model, provider: RailsAiAdmin.configuration.assistant_provider&.to_sym, context: llm)
          end
          klass
        end

        def name = super || "RailsAiAdmin::Assistant::Evaluation"

        # One line per case and a total, for the rake task.
        def summary(report)
          lines = report.trials.map do |trial|
            answer = trial.result
            detail = trial.error&.message || trial.assertion_failure&.message ||
              trial.evaluations.reject(&:passed?).map { |evaluation| "#{evaluation.name}: #{evaluation.status}" }.join("; ").presence
            tools = answer.respond_to?(:tools) && answer.tools.any? ? " [#{answer.tools.join(', ')}]" : ""
            "#{trial.status.to_s.upcase.ljust(10)} #{trial.test_case.name}#{tools}#{" - #{detail}" if detail}"
          end
          passed = report.trials.count(&:passed?)
          cost = report.cost.total
          lines << "#{passed} of #{report.trials.size} passed#{cost ? format(', US$%.4f', cost) : ''}."
        end

        private

        def check_case!(test_case)
          unless test_case.inputs.is_a?(String) && test_case.inputs.strip.length.between?(1, Coordinator::MAX_CONTENT)
            raise ConfigurationError, "Case #{test_case.name}: inputs must be the question text"
          end
          unknown = test_case.metadata.keys.map(&:to_s) - CHECKS
          raise ConfigurationError, "Case #{test_case.name}: unknown metadata #{unknown.join(', ')}" if unknown.any?
          CHECKS.each do |key|
            value = test_case.metadata[key] || test_case.metadata[key.to_sym]
            next if value.nil? || value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
            raise ConfigurationError, "Case #{test_case.name}: #{key} must be a list of text"
          end
        end
      end

      def perform(question)
        chat = Assistant.create_chat!(self.class.context)
        @chat = chat
        Coordinator.admit!(chat, kind: "message", content: question, admission_key: "eval:#{SecureRandom.uuid}")
        Coordinator.new.run(chat.ref)
        turn = chat.turns.reload.last
        messages = chat.messages.reload.includes(:ruby_llm_tool_calls)
        text = messages.select { |message| message.role == "assistant" && message.content.present? }.last&.content.to_s
        Answer.new(text: text, tools: messages.flat_map { |message| message.ruby_llm_tool_calls.map(&:name) },
          status: turn.status, error_code: turn.error_code, chat_ref: chat.ref)
      end

      def assertions
        answer = result
        assert_equal "completed", answer.status, "The turn ended as #{answer.status} (#{answer.error_code || 'no code'})"
        check("tools").each { |tool| assert_includes answer.tools, tool, "#{tool} was not called" }
        check("tools_absent").each { |tool| refute_includes answer.tools, tool, "#{tool} was called" }
        check("answer_includes").each do |text|
          assert answer.text.downcase.include?(text.downcase), "The answer does not contain #{text.inspect}"
        end
      end

      # The conversation is archived, so it leaves the person's list; a turn
      # still waiting for a retry is cancelled rather than run later.
      def teardown
        return unless @chat
        @chat.turns.where(status: "queued").update_all(status: "cancelled", error_code: "CANCELLED", completed_at: Time.current, updated_at: Time.current)
        @chat.update!(status: "archived")
      end

      private

      def check(key) = Array(metadata[key] || metadata[key.to_sym])
    end
  end
end
