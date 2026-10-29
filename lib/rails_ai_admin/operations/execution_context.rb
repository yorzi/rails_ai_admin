# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    class ExecutionContext
      class DeadlineExceeded < StandardError; end
      class PreviewOutbox
        def enqueue(*)
          raise ConfigurationError, "Preflight cannot enqueue outbox work"
        end
      end
      attr_reader :outbox

      def initialize(context, resource, record, run: nil, duration: 5)
        @context, @resource, @record = context, resource, record
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
        @outbox = run ? Outbox::Writer.new(context, run, resource) : PreviewOutbox.new
      end

      %i[actor tenant security_version time_zone actor_ref tenant_ref].each do |method|
        define_method(method) { @context.public_send(method) }
      end

      def check_deadline!
        raise DeadlineExceeded if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
      end

      def ref(record)
        unless record.is_a?(@resource.model_class) && record.id.to_s == @record.id.to_s
          raise ConfigurationError, "References must identify this operation's scoped target"
        end
        value = "raa:record:#{record.class.base_class.name}:#{record.id}"
        raise ConfigurationError, "Record reference is too long" if value.bytesize > 150
        value
      end
    end
  end
end
