# frozen_string_literal: true

require "json_schemer"

module RailsAiAdmin
  module Fields
    # A deliberately scalar-only subset of the released Surface schema contract.
    # Core constraints stay outside the extension in an intersection.
    module ScalarSchema
      SHARED_KEYS = %w[type enum const title description].freeze
      TYPE_KEYS = { "string" => %w[pattern minLength maxLength], "integer" => %w[minimum maximum], "boolean" => [] }.freeze
      def self.scalar?(value)
        value.nil? || value == true || value == false || value.is_a?(String) && value.valid_encoding? ||
          value.is_a?(Integer) || value.is_a?(Float) && value.finite?
      end
      private_class_method :scalar?

      def self.compile(base, constraints)
        unless constraints.is_a?(Hash) && constraints.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } && constraints.stringify_keys.size == constraints.size
          raise ConfigurationError, "Field schema constraints must be a scalar keyword hash"
        end
        constraints = constraints.stringify_keys
        allowed_keys = SHARED_KEYS + TYPE_KEYS.fetch(base.fetch("type"))
        if (constraints.keys - allowed_keys).any? || constraints.key?("type") && constraints["type"] != base.fetch("type")
          raise ConfigurationError, "Field schema cannot change the core scalar type or use unsupported keywords"
        end
        if constraints["pattern"] && (!constraints["pattern"].is_a?(String) || constraints["pattern"].bytesize > 1000)
          raise ConfigurationError, "Field schema pattern must be bounded text"
        end
        %w[title description].each do |key|
          raise ConfigurationError, "Field schema text must be bounded" if constraints[key] && (!constraints[key].is_a?(String) || constraints[key].bytesize > 300)
        end
        if constraints.key?("const") && !scalar?(constraints["const"]) || constraints.key?("enum") &&
            (!constraints["enum"].is_a?(Array) || !constraints["enum"].all? { |value| scalar?(value) })
          raise ConfigurationError, "Field enum and const constraints must contain JSON scalars"
        end
        encoded = JSON.generate(constraints)
        raise ConfigurationError, "Field schema is too large" if encoded.bytesize > 8192
        constraints = JSON.parse(encoded)
        schema = constraints.empty? ? base : base.merge("allOf" => [ constraints ])
        validator = JSONSchemer.schema(schema, ref_resolver: ->(*) { raise ConfigurationError, "Field schema references are unsupported" })
        raise ConfigurationError, "Invalid scalar field schema" unless validator.valid_schema?
        [ schema, validator ]
      rescue JSON::GeneratorError, JSON::ParserError, EncodingError, RegexpError, ArgumentError
        raise ConfigurationError, "Invalid scalar field schema", cause: nil
      end
    end
  end
end
