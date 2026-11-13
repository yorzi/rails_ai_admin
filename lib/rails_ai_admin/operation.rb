# frozen_string_literal: true

module RailsAiAdmin
  # Trusted, synchronous domain code. All persistence belongs to Runner's transaction.
  class Operation
    Outcome = Data.define(:code, :record_id, :fields)

    class << self
      def inherited(child)
        super
        child.instance_variable_set(:@input_fields, {})
        child.instance_variable_set(:@atomic_models, [])
      end

      def input(&block)
        Resource::FieldBuilder.new(@input_fields).instance_eval(&block) if block
        # Operation inputs persist in collection payloads and Surface reviews.
        if @input_fields.each_value.any? { |field| %i[password file].include?(field.scalar_type) }
          raise ConfigurationError, "Operation inputs cannot be passwords or files"
        end
        @input_fields.values
      end

      def version(value = nil)
        @version = value if value
        @version || "1"
      end

      def description(value = nil)
        @description = value if value
        @description || name.demodulize.underscore.humanize
      end

      def atomic_models(*names)
        @atomic_models.concat(names) if names.any?
        @atomic_models
      end

      def max_duration(value = nil)
        @max_duration = value if value
        @max_duration || 5
      end

      def lease_duration(value = nil)
        @lease_duration = value if value
        @lease_duration || 60
      end

      def execution_window(value = nil)
        @execution_window = value if value
        @execution_window || 1.hour
      end

      def max_attempts(value = nil)
        @max_attempts = value if value
        @max_attempts || 3
      end

      def read_only? = false
      def expose_to_ai? = false
      def approval_policy = :required
      def idempotency_policy = :intent
      def audit_policy = :required
      def perform_arity = 3

      def validate!
        unless version.is_a?(String) && version.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/)
          raise ConfigurationError, "Operation version must be a bounded string"
        end
        unless description.is_a?(String) && description.length.between?(1, 300) && max_duration.is_a?(Numeric) && max_duration > 0 && max_duration <= 30
          raise ConfigurationError, "Operation needs a description and duration between 0 and 30 seconds"
        end
        unless atomic_models.all? { |name| name.is_a?(String) && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) }
          raise ConfigurationError, "atomic_models must contain model class-name strings"
        end
        raise ConfigurationError, "Operation inputs cannot be readonly or hidden" if input.any? { |field| field.options[:readonly] || field.hidden? }
        raise ConfigurationError, "Operation must implement perform" if instance_method(:perform).owner == Operation
        unless respond_to?(:new) && accepts_arguments?(method(:new), 0) && accepts_arguments?(instance_method(:initialize), 0) &&
            %i[preflight perform].all? { |name| public_instance_methods.include?(name) } && accepts_arguments?(instance_method(:preflight), 3) && accepts_arguments?(instance_method(:perform), perform_arity)
          raise ConfigurationError, "Operation handler has an incompatible public constructor or method signature"
        end
        @input_fields.freeze
        @atomic_models.each(&:freeze)
        @atomic_models.freeze
        version.freeze
        description.freeze
        self
      end

      private

      def accepts_arguments?(method, count)
        parameters = method.parameters
        minimum = parameters.count { |kind, _| kind == :req }
        maximum = parameters.any? { |kind, _| kind == :rest } ? Float::INFINITY : minimum + parameters.count { |kind, _| kind == :opt }
        (minimum..maximum).cover?(count) && parameters.none? { |kind, _| kind == :keyreq }
      end
    end

    # Return proposed new values by resource field name. Runner supplies the
    # authorized original values and filters/coerces this preview before display.
    def preflight(_context, _record, _input) = {}

    def perform(_context, _record, _input)
      raise NotImplementedError
    end

    def success(record)
      Outcome.new("OK", record.id.to_s, [].freeze)
    end

    def invalid(*fields)
      Outcome.new("VALIDATION_FAILED", nil, fields.map(&:to_s).freeze)
    end

    def conflict
      Outcome.new("CONFLICT", nil, [].freeze)
    end
  end
end
