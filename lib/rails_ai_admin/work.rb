# frozen_string_literal: true

module RailsAiAdmin
  # Trusted post-commit delivery. One item permits one explicit external effect.
  class Work < Operation
    class << self
      def perform_arity = 2

      def idempotent(value = nil)
        @idempotent = value unless value.nil?
        @idempotent == true
      end

      def lease_duration(value = nil)
        @lease_duration = value if value
        @lease_duration || 60
      end

      def max_attempts(value = nil)
        @max_attempts = value if value
        @max_attempts || 3
      end

      def max_age(value = nil)
        @max_age = value if value
        @max_age || 1.day
      end

      def record_version_policy(value = nil)
        @record_version_policy = value if value
        @record_version_policy || :exact
      end

      def validate!
        super
        unless (5..3600).cover?(lease_duration) && max_attempts.is_a?(Integer) && (1..10).cover?(max_attempts) && (60..7.days).cover?(max_age) && %i[exact current].include?(record_version_policy)
          raise ConfigurationError, "Invalid Work lease, retry, lifetime or record-version policy"
        end
        raise ConfigurationError, "Work must implement perform" if instance_method(:perform).owner == Work
        self
      end
    end

    def perform(_context, _input)
      raise NotImplementedError
    end
  end
end
