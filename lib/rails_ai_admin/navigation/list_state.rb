# frozen_string_literal: true

require "base64"

module RailsAiAdmin
  module Navigation
    # A non-authoritative list hint, never a route/host/record capability.
    class ListState
      KEYS = %w[q sort direction page scope].freeze
      MAX_HEADER_BYTES = 2048
      MAX_JSON_BYTES = 1024
      INVALID = Object.new.freeze
      attr_reader :state

      def self.from_header(access, value)
        raw = if value.nil? || value == ""
          nil
        elsif value.is_a?(String) && value.bytesize <= MAX_HEADER_BYTES
          begin
            decoded = Base64.urlsafe_decode64(value).force_encoding(Encoding::UTF_8)
            decoded.bytesize <= MAX_JSON_BYTES && decoded.valid_encoding? ? JSON.parse(decoded) : INVALID
          rescue ArgumentError, JSON::ParserError
            INVALID
          end
        else
          INVALID
        end
        new(access, raw)
      end

      def initialize(access, raw = nil, strict: false)
        @discarded = false
        values = parse(raw)
        raise AccessDenied, "INVALID_QUERY" if strict && @discarded
        @index_allowed = begin
          access.authorize!(:index)
        rescue AccessDenied
          false
        end
        raise AccessDenied if strict && !@index_allowed
        unless @index_allowed
          @discarded ||= values.any?
          @state = {}.freeze
          freeze
          return
        end
        if values["q"] && access.fields(:search).empty?
          values.delete("q")
          @discarded = true
        end
        if strict && values["sort"] && !access.resource.fields.any? { |field| field.name.to_s == values["sort"] && !field.hidden? && !field.virtual? && field.options[:sortable] }
          raise AccessDenied, "INVALID_QUERY"
        end
        if values["sort"] && !access.fields(:sort).any? { |field| field.name.to_s == values["sort"] }
          values.delete("sort")
          values.delete("direction")
          @discarded = true
        end
        normalize_scope!(access, values, strict)
        values.delete("page") if @discarded
        values.delete("direction") unless values["sort"]
        @state = values.transform_values { |value| String.new(value).freeze }.freeze
        freeze
      end

      def index_allowed? = @index_allowed
      def discarded? = @discarded
      def encoded = state.empty? ? "" : Base64.urlsafe_encode64(JSON.generate(state), padding: false)

      private

      # Undeclared scopes are invalid only for strict index requests. A revoked
      # grant is discarded; the currently granted default is implicit.
      def normalize_scope!(access, values, strict)
        name = values["scope"]
        return unless name
        if strict && access.resource.scopes.none? { |definition| definition.name.to_s == name }
          raise AccessDenied, "INVALID_QUERY"
        end
        granted = access.named_scopes
        if granted.none? { |definition| definition.name.to_s == name }
          values.delete("scope")
          @discarded = true
        elsif granted.find(&:default?)&.name&.to_s == name
          values.delete("scope")
        end
      end

      def parse(raw)
        return {} if raw.nil?
        unless raw.is_a?(Hash) && raw.size <= KEYS.size && raw.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          @discarded = true
          return {}
        end
        values = raw.stringify_keys
        valid = (values.keys - KEYS).empty? && values.values.all? { |value| value.nil? || value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) }
        valid &&= !values["q"] || values["q"].length <= 200 && !values["q"].match?(/[\x00-\x1f\x7f]/)
        valid &&= !values["sort"] || values["sort"] == "" || values["sort"].match?(/\A[a-z][a-z0-9_]{0,79}\z/)
        valid &&= !values["direction"] || %w[asc desc].include?(values["direction"])
        valid &&= !values["page"] || values["page"].match?(/\A[1-9]\d{0,3}\z/) && values["page"].to_i <= 1000
        valid &&= !values["scope"] || values["scope"] == "" || values["scope"].match?(Queries::NamedScope::NAME)
        unless valid
          @discarded = true
          return {}
        end
        values.reject { |key, value| value.blank? || key == "page" && value == "1" || key == "direction" && value == "asc" }
      end
    end
  end
end
