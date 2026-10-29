# frozen_string_literal: true

require "json"
require "digest"

module RailsAiAdmin
  # Compiles explicitly declared fields into typed inputs and canonical digests.
  class InputSchema
    Coercion = Data.define(:values, :errors) do
      def valid? = errors.empty?
    end

    def initialize(fields, partial: false)
      @fields = fields.index_by { |field| field.name.to_s }
      @partial = partial
    end

    def coerce(input, time_zone: "UTC")
      return Coercion.new({}, { "base" => [ "must be an object" ] }) unless input.is_a?(Hash)
      values, errors = {}, {}
      input = input.stringify_keys
      errors["base"] = [ "contains undeclared fields" ] if (input.keys - @fields.keys).any?
      @fields.each do |name, field|
        if !input.key?(name)
          errors[name] = [ "is required" ] if !@partial && field.options[:required]
          next
        end
        begin
          values[name] = field.coerce(input[name], time_zone: time_zone)
        rescue ArgumentError => error
          errors[name] = [ error.message ]
        end
      end
      Coercion.new(values.freeze, errors.freeze)
    end

    def json_schema
      required = @partial ? [] : @fields.values.select { |field| field.options[:required] }.map { |field| field.name.to_s }
      { "type" => "object", "properties" => @fields.transform_values(&:json_schema), "required" => required, "additionalProperties" => false }
    end

    # Serializes semantic values independently of hash insertion order.
    def self.digest(input)
      Digest::SHA256.hexdigest(JSON.generate(canonical(input)))
    end

    def self.canonical(value)
      case value
      when Hash then value.stringify_keys.sort.to_h.transform_values { |entry| canonical(entry) }
      when Array then value.map { |entry| canonical(entry) }
      when BigDecimal then { "$decimal" => value.to_s("F") }
      when Time, ActiveSupport::TimeWithZone then { "$time" => value.utc.iso8601(6) }
      when Date then { "$date" => value.iso8601 }
      else value
      end
    end
  end
end
