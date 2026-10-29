# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module RailsAiAdmin
  # Declares one scalar input/output contract. All presentation and query flags
  # only narrow the permissions returned by the host policy.
  class Field
    TYPES = %i[id text textarea integer decimal boolean date datetime enum].freeze
    OPTIONS = %i[readonly required nullable values max_length searchable sortable create edit label].freeze
    attr_reader :name, :type, :options

    def initialize(name, type:, **options)
      @name, @type = name.to_sym, type.to_sym
      raise ConfigurationError, "Invalid field name" unless @name.to_s.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ConfigurationError, "Unknown field type #{@type}" unless TYPES.include?(@type)
      raise ConfigurationError, "Unknown field option" unless (options.keys - OPTIONS).empty?
      defaults = { readonly: type == :id, nullable: true, required: false, max_length: 2000, create: true, edit: true }
      @options = defaults.merge(options).deep_dup
      @options[:values]&.each(&:freeze)
      @options[:values]&.freeze
      @options.each_value { |value| value.freeze }
      @options.freeze
      if @type == :enum && (!@options[:values].is_a?(Array) || @options[:values].empty? || !@options[:values].all? { |value| value.is_a?(String) })
        raise ConfigurationError, "Enum requires string values"
      end
      freeze
    end

    def label
      options[:label] || name.to_s.humanize
    end

    def writable?(operation)
      !options[:readonly] && options[operation.to_sym == :create ? :create : :edit]
    end

    # Formats an already-authorized scalar for conventional pages.
    def format(value, time_zone: "UTC")
      return "—" if value.nil?
      case type
      when :boolean then value ? "Yes" : "No"
      when :decimal then value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      when :datetime then value.in_time_zone(time_zone).iso8601
      when :date then value.iso8601
      else value.to_s
      end
    end

    # Coerces form or JSON scalar values, preserving false, zero and null.
    def coerce(value, time_zone: "UTC")
      if value.nil? || (value == "" && !%i[text textarea].include?(type))
        raise ArgumentError, "cannot be blank" unless options[:nullable]
        return nil
      end
      case type
      when :text, :textarea, :id
        raise ArgumentError, "must be text" unless value.is_a?(String)
        raise ArgumentError, "is too long" if value.length > options[:max_length]
        value.dup
      when :enum
        raise ArgumentError, "is not an allowed value" unless options[:values].include?(value)
        value.dup
      when :integer
        raise ArgumentError, "must be an integer" unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[+-]?\d+\z/))
        raise ArgumentError, "is out of range" if value.is_a?(String) && value.length > 100
        number = value.is_a?(String) ? Integer(value, 10) : value
        raise ArgumentError, "is out of range" unless (-(2**63)..(2**63 - 1)).cover?(number)
        number
      when :decimal
        raise ArgumentError, "must be a decimal" unless value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/))
        BigDecimal(value.to_s)
      when :boolean
        return true if [ true, "1", "true" ].include?(value)
        return false if [ false, "0", "false" ].include?(value)
        raise ArgumentError, "must be a boolean"
      when :date
        raise ArgumentError, "must be an ISO date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      when :datetime
        raise ArgumentError, "must be an ISO timestamp" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})?\z/)
        # datetime-local inputs are interpreted in the authenticated context zone.
        zone = ActiveSupport::TimeZone[time_zone]
        zone.iso8601(value).utc
      end
    rescue Date::Error, TypeError
      raise ArgumentError, "is invalid"
    end

    # Returns the supported JSON Schema subset, shared by future tool adapters.
    def json_schema
      schema = case type
      when :integer then { "type" => "integer" }
      when :decimal then { "type" => "string", "pattern" => "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$" }
      when :boolean then { "type" => "boolean" }
      when :enum then { "type" => "string", "enum" => options[:values] }
      else { "type" => "string", "maxLength" => options[:max_length] }
      end
      options[:nullable] ? { "anyOf" => [ schema, { "type" => "null" } ] } : schema
    end
  end
end
