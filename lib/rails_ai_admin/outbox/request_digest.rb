# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    # Unlike typed input digests, request fingerprints have no type-marker domain.
    # Accept only plain JSON data and reject keys that collide after normalization.
    module RequestDigest
      def self.call(request)
        raise ConfigurationError, "Effect request must be an object" unless request.is_a?(Hash)
        body = JSON.generate(normalize(request))
        raise ConfigurationError, "Effect request exceeds 16384 bytes" if body.bytesize > 16_384
        Digest::SHA256.hexdigest(body)
      rescue JSON::GeneratorError
        raise ConfigurationError, "Effect request must contain valid JSON data", cause: nil
      end

      def self.normalize(value, depth = 0)
        raise ConfigurationError, "Effect request nesting is too deep" if depth > 8
        case value
        when Hash
          normalized = {}
          value.each do |key, entry|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ConfigurationError, "Effect request keys must be strings or symbols"
            end
            name = key.to_s
            raise ConfigurationError, "Effect request has duplicate normalized keys" if normalized.key?(name)
            normalized[name] = normalize(entry, depth + 1)
          end
          normalized.sort.to_h
        when Array then value.map { |entry| normalize(entry, depth + 1) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        when Float
          raise ConfigurationError, "Effect request numbers must be finite" unless value.finite?
          value
        else
          raise ConfigurationError, "Serialize typed values to plain JSON scalars before effect admission"
        end
      end
    end
  end
end
