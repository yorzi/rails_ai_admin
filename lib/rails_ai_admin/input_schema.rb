# frozen_string_literal: true

require "json"
require "digest"
require "openssl"
require "securerandom"

module RailsAiAdmin
  # Compiles explicitly declared fields into typed inputs and canonical digests.
  class InputSchema
    Coercion = Data.define(:values, :errors) do
      def valid? = errors.empty?
    end

    def initialize(fields, partial: false)
      raise ConfigurationError, "Computed fields cannot be input fields" if fields.any?(&:virtual?)
      @fields = fields.index_by { |field| field.name.to_s }
      @partial = partial
    end

    def coerce(input, time_zone: "UTC")
      return Coercion.new({}, { "base" => [ Field.error_message(:not_object, "must be an object") ] }) unless input.is_a?(Hash)
      values, errors = {}, {}
      input = input.stringify_keys
      errors["base"] = [ Field.error_message(:undeclared_fields, "contains undeclared fields") ] if (input.keys - @fields.keys).any?
      @fields.each do |name, field|
        # An empty password box means "keep the current password".
        input_value = input[name]
        if !input.key?(name) || field.scalar_type == :password && input_value.is_a?(String) && input_value.match?(Field::BLANK)
          errors[name] = [ Field.error_message(:required, "is required") ] if !@partial && field.options[:required]
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

    # Keyed so a stored digest is not an unsalted hash of a password. Hosts
    # derive it from secret_key_base; without an application (plain library
    # tests) it is random per process.
    def self.secret_key
      @secret_key ||= if defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.respond_to?(:key_generator) && Rails.application.secret_key_base.present?
        Rails.application.key_generator.generate_key("rails_ai_admin/input_digest", 32)
      else
        SecureRandom.bytes(32)
      end
    end

    def self.canonical(value)
      case value
      when Hash then value.stringify_keys.sort.to_h.transform_values { |entry| canonical(entry) }
      when Array then value.map { |entry| canonical(entry) }
      when BigDecimal then { "$decimal" => value.to_s("F") }
      when Time, ActiveSupport::TimeWithZone then { "$time" => value.utc.iso8601(6) }
      when Date then { "$date" => value.iso8601 }
      when Fields::FileValue, Fields::RejectedUpload then value.to_h.transform_keys(&:to_s)
      when Field::Secret then { "$secret" => OpenSSL::HMAC.hexdigest("SHA256", secret_key, value) }
      else value
      end
    end
  end
end
