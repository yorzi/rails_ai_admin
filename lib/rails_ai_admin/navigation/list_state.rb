# frozen_string_literal: true

require "base64"

module RailsAiAdmin
  module Navigation
    # A non-authoritative list hint, never a route/host/record capability.
    class ListState
      KEYS = %w[q sort direction page scope filter].freeze
      FILTER_OPERATORS = Field::FILTER_OPERATORS.map(&:to_s).freeze
      MAX_HEADER_BYTES = 2048
      # Base64 of 1536 bytes is exactly the 2048-byte header bound.
      MAX_JSON_BYTES = 1536
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
        normalize_filter!(access, values, strict)
        values.delete("page") if @discarded
        values.delete("direction") unless values["sort"]
        @state = deep_copy(values)
        freeze
      end

      # Hidden form inputs for a (possibly nested) state, e.g. return_to[filter][total][gte].
      def self.form_pairs(state, prefix = nil)
        state.flat_map do |key, value|
          name = prefix ? "#{prefix}[#{key}]" : key.to_s
          value.is_a?(Hash) ? form_pairs(value, name) : [ [ name, value ] ]
        end
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

      # Undeclared filters/operators are invalid for strict index requests.
      # Revoked grants or values outside the field contract are discarded.
      def normalize_filter!(access, values, strict)
        filter = values["filter"]
        return unless filter
        declared = access.resource.fields.reject { |field| field.hidden? || field.virtual? || field.filter_operators.empty? }.index_by { |field| field.name.to_s }
        granted = access.fields(:filter).index_by { |field| field.name.to_s }
        if strict && filter.any? { |name, conditions| !declared[name] || conditions.keys.any? { |operator| !declared[name].filter_operators.include?(operator.to_sym) } }
          raise AccessDenied, "INVALID_QUERY"
        end
        kept = {}
        access.resource.fields.each do |field|
          conditions = filter[field.name.to_s]
          next unless conditions
          FILTER_OPERATORS.each do |operator|
            next unless conditions.key?(operator)
            if granted[field.name.to_s]&.filter_operators&.include?(operator.to_sym) && valid_filter_value?(access, field, operator, conditions[operator])
              (kept[field.name.to_s] ||= {})[operator] = conditions[operator]
            else
              raise AccessDenied, "INVALID_QUERY" if strict && granted[field.name.to_s]
              @discarded = true
            end
          end
        end
        @discarded = true if filter.keys.any? { |name| !access.resource.fields.any? { |field| field.name.to_s == name } }
        if kept.empty?
          values.delete("filter")
        else
          values["filter"] = kept
        end
      end

      def valid_filter_value?(access, field, operator, value)
        Queries::List.filter_value(field, operator, value, time_zone: access.context.time_zone)
        true
      rescue AccessDenied
        false
      end

      def parse_filter(value)
        return {} if value.nil? || value == ""
        return INVALID unless value.is_a?(Hash) && value.size <= Queries::List::MAX_FILTER_CONDITIONS
        parsed = {}
        value.each do |name, conditions|
          return INVALID unless (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(/\A[a-z][a-z0-9_]{0,79}\z/) && conditions.is_a?(Hash)
          conditions.each do |operator, condition|
            return INVALID unless (operator.is_a?(String) || operator.is_a?(Symbol)) && FILTER_OPERATORS.include?(operator.to_s)
            return INVALID unless condition.nil? || condition.is_a?(String) && condition.valid_encoding? && (condition.encoding == Encoding::UTF_8 || condition.ascii_only?) && condition.length <= 200 && !condition.match?(/[\x00-\x1f\x7f]/)
            next if condition.blank?
            (parsed[name.to_s] ||= {})[operator.to_s] = condition
          end
        end
        parsed.values.sum(&:size) <= Queries::List::MAX_FILTER_CONDITIONS ? parsed : INVALID
      end

      def deep_copy(value)
        value.is_a?(Hash) ? value.to_h { |key, item| [ String.new(key.to_s).freeze, deep_copy(item) ] }.freeze : String.new(value).freeze
      end

      def parse(raw)
        return {} if raw.nil?
        unless raw.is_a?(Hash) && raw.size <= KEYS.size && raw.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          @discarded = true
          return {}
        end
        values = raw.stringify_keys
        filter = parse_filter(values.delete("filter"))
        valid = !filter.equal?(INVALID) && (values.keys - KEYS).empty? && values.values.all? { |value| value.nil? || value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) }
        valid &&= !values["q"] || values["q"].length <= 200 && !values["q"].match?(/[\x00-\x1f\x7f]/)
        valid &&= !values["sort"] || values["sort"] == "" || values["sort"].match?(/\A[a-z][a-z0-9_]{0,79}\z/)
        valid &&= !values["direction"] || %w[asc desc].include?(values["direction"])
        valid &&= !values["page"] || values["page"].match?(/\A[1-9]\d{0,3}\z/) && values["page"].to_i <= 1000
        valid &&= !values["scope"] || values["scope"] == "" || values["scope"].match?(Queries::NamedScope::NAME)
        unless valid
          @discarded = true
          return {}
        end
        values = values.reject { |key, value| value.blank? || key == "page" && value == "1" || key == "direction" && value == "asc" }
        filter.empty? ? values : values.merge("filter" => filter)
      end
    end
  end
end
