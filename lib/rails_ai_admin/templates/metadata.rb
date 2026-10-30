# frozen_string_literal: true

require "json"
require "rails_ai_admin/version"

module RailsAiAdmin
  module Templates
    module Metadata
      PREFIX = "<%# rails_ai_admin:override "
      MAX_BYTES = 1024
      KEYS = %w[format key gem_version source_sha256 contract].freeze
      class HeaderObject < Hash
        def []=(key, value)
          raise JSON::ParserError, "Duplicate metadata key" if key?(key)
          super
        end
      end

      def self.line(entry, catalog)
        data = { "format" => 1, "key" => entry.key, "gem_version" => VERSION,
          "source_sha256" => catalog.source_digest(entry), "contract" => entry.revision }
        "#{PREFIX}#{JSON.generate(data)} %>\n"
      end

      def self.read(path, entry)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        line = File.open(path, flags) { |file| file.gets("\n", MAX_BYTES + 1) }.to_s.force_encoding(Encoding::UTF_8)
        return unless line.b.start_with?(PREFIX.b)
        raise ConfigurationError, "Invalid override header" if line.bytesize > MAX_BYTES || !line.valid_encoding?
        json = line.match(/\A<%# rails_ai_admin:override (\{.*\}) %>\r?\n?\z/)&.captures&.first
        raise ConfigurationError, "Invalid override header" unless json
        data = JSON.parse(json, object_class: HeaderObject, max_nesting: 2)
        unless data.keys.sort == KEYS.sort && data["format"].is_a?(Integer) && data["format"] == 1 && data["key"] == entry.key &&
            data["contract"].is_a?(Integer) && data["contract"].between?(1, 1_000_000) &&
            data["source_sha256"].is_a?(String) && data["source_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
            data["gem_version"].is_a?(String) && data["gem_version"].match?(/\A[0-9a-zA-Z][0-9a-zA-Z.-]{0,63}\z/) && Gem::Version.correct?(data["gem_version"])
          raise ConfigurationError, "Invalid override header"
        end
        data.freeze
      rescue JSON::ParserError, EncodingError
        raise ConfigurationError, "Invalid override header", cause: nil
      end
    end
  end
end
