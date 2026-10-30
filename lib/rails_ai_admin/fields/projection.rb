# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    # One current projection, with no cross-request/identity value cache.
    class Projection
      MAX_VALUE_BYTES = 16_384
      MAX_OUTPUT_BYTES = 65_536
      MAX_SECONDS = 1.0

      def initialize(access, record, fields)
        @access, @record = access, record
        @fields = fields.index_by(&:name)
        @computed = fields.any?(&:virtual?)
        @cache = {}
        @bytes = 0
        @deadline = monotonic + MAX_SECONDS
      end

      def values
        result = @fields.values.to_h { |field| [ field.name.to_s, value(field) ] }
        check_deadline!
        result
      end

      def value(field)
        check_deadline!
        return @cache[field.name] if @cache.key?(field.name)
        raise AccessDenied unless @fields[field.name].equal?(field)
        unless field.virtual?
          scalar = @access.read_attribute(@record, field)
          check_deadline!
          return @cache[field.name] = scalar
        end
        computed = ActiveRecord::Base.while_preventing_writes do
          dependencies = field.dependencies.to_h { |name| [ name.to_s, snapshot(value(@fields.fetch(name))) ] }.freeze
          check_bound!(dependencies)
          field.compute(dependencies, time_zone: @access.context.time_zone)
        end
        check_deadline!
        @bytes += check_bound!(computed)
        raise ConfigurationError, "Computed projection exceeds output bound" if @bytes > MAX_OUTPUT_BYTES
        @cache[field.name] = computed
      end

      private

      def snapshot(value)
        copy = case value
        when nil, true, false, Integer then value
        when String then String.new(value)
        when BigDecimal
          raise ConfigurationError, "Computed dependencies require finite decimals" unless value.finite?
          value
        when Time, ActiveSupport::TimeWithZone, DateTime then value.to_time.getutc
        when Date then Date.iso8601(value.iso8601)
        else raise ConfigurationError, "Computed dependencies require supported scalars"
        end
        check_bound!(copy)
        copy.freeze
      end

      def check_bound!(value)
        bytes = JSON.generate(InputSchema.canonical(value)).bytesize
        raise ConfigurationError, "Computed scalar exceeds size bound" if bytes > MAX_VALUE_BYTES
        bytes
      rescue JSON::GeneratorError, EncodingError
        raise ConfigurationError, "Computed scalar encoding is invalid", cause: nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def check_deadline!
        raise ConfigurationError, "Computed projection exceeded its cooperative budget" if @computed && monotonic > @deadline
      end
    end
  end
end
