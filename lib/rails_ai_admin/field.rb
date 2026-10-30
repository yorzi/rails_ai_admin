# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module RailsAiAdmin
  # Declares one scalar input/output contract. All presentation and query flags
  # only narrow the permissions returned by the host policy.
  class Field
    TYPES = %i[id text textarea integer decimal boolean date datetime enum select].freeze
    OPTIONS = %i[readonly required nullable values max_length searchable sortable create edit label choices].freeze
    Descriptor = Data.define(:name, :type, :scalar_type, :options, :scalar_json_schema)
    attr_reader :name, :type, :scalar_type, :options

    def initialize(name, type:, plugin: nil, **options)
      @name, @type = name.to_sym, type.to_sym
      @plugin = plugin
      @plugin_metadata = plugin && immutable_copy(plugin.metadata)
      @scalar_type = @plugin_metadata ? @plugin_metadata.fetch(:scalar) : @type
      raise ConfigurationError, "Invalid field name" unless @name.to_s.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ConfigurationError, "Unknown field type" unless TYPES.include?(@scalar_type) && (plugin || TYPES.include?(@type))
      raise ConfigurationError, "Unknown field option" unless (options.keys - OPTIONS).empty?
      defaults = { readonly: @scalar_type == :id, nullable: true, required: false, max_length: 2000, create: true, edit: true }
      @options = immutable_copy(defaults.merge(options))
      validate_options!
      @descriptor = Descriptor.new(@name, @type, @scalar_type, @options, immutable_copy(scalar_json_schema))
      if @plugin
        constraints = invoke(:schema, field: @descriptor)
        schema, @validator = Fields::ScalarSchema.compile(@descriptor.scalar_json_schema, constraints)
      else
        schema = @descriptor.scalar_json_schema
      end
      @json_schema = immutable_copy(@options[:nullable] ? { "anyOf" => [ schema, { "type" => "null" } ] } : schema)
      @contract = immutable_copy(name: @name, type: @type, scalar: @scalar_type, options: @options, plugin: @plugin_metadata, schema: @json_schema)
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
      text = scalar_format(value, time_zone: time_zone)
      text = invoke(:format, text.freeze, field: @descriptor, time_zone: time_zone) if @plugin && !value.nil?
      raise ConfigurationError, "Field formatter must return bounded plain text" unless text.is_a?(String) && text.bytesize <= 16_384 && text.valid_encoding?
      String.new(text)
    end

    def scalar_format(value, time_zone: "UTC")
      return "—" if value.nil?
      case scalar_type
      when :boolean then value ? "Yes" : "No"
      when :decimal then value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      when :datetime then value.in_time_zone(time_zone).iso8601(6)
      when :date then value.iso8601
      when :select then choice_options.find { |_, key| key == value }&.first || value.to_s
      else value.to_s
      end
    end

    # Coerces form or JSON scalar values, preserving false, zero and null.
    def coerce(value, time_zone: "UTC")
      typed = coerce_scalar(value, time_zone: time_zone)
      return typed unless @plugin && !typed.nil?
      normalized = invoke(:normalize, immutable_copy(typed), field: @descriptor, time_zone: time_zone)
      normalized = coerce_scalar(wire(normalized), time_zone: time_zone)
      repeated = invoke(:normalize, immutable_copy(normalized), field: @descriptor, time_zone: time_zone)
      repeated = coerce_scalar(wire(repeated), time_zone: time_zone)
      raise ConfigurationError, "Field normalization must be idempotent" unless normalized == repeated
      valid = invoke(:valid?, immutable_copy(normalized), field: @descriptor, time_zone: time_zone)
      raise ConfigurationError, "Field validation must return a boolean" unless [ true, false ].include?(valid)
      raise ArgumentError, "is invalid" unless valid && @validator.valid?(wire(normalized))
      normalized
    rescue ArgumentError
      raise ArgumentError, "is invalid", cause: nil if @plugin
      raise
    end

    def coerce_scalar(value, time_zone: "UTC")
      if value.nil? || (value == "" && !%i[text textarea].include?(scalar_type))
        raise ArgumentError, "cannot be blank" unless options[:nullable]
        return nil
      end
      case scalar_type
      when :text, :textarea, :id
        raise ArgumentError, "must be text" unless value.is_a?(String)
        raise ArgumentError, "is too long" if value.length > options[:max_length]
        raise ArgumentError, "is invalid" unless value.valid_encoding?
        String.new(value)
      when :enum, :select
        raise ArgumentError, "is not an allowed value" unless choice_values.include?(value)
        raise ArgumentError, "is invalid" unless value.valid_encoding?
        String.new(value)
      when :integer
        raise ArgumentError, "must be an integer" unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[+-]?\d+\z/))
        raise ArgumentError, "is out of range" if value.is_a?(String) && value.length > 100
        number = value.is_a?(String) ? Integer(value, 10) : value
        raise ArgumentError, "is out of range" unless (-(2**63)..(2**63 - 1)).cover?(number)
        number
      when :decimal
        raise ArgumentError, "must be a decimal" unless value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/))
        number = BigDecimal(value.to_s)
        raise ArgumentError, "must be finite" unless number.finite?
        number
      when :boolean
        return true if [ true, "1", "true" ].include?(value)
        return false if [ false, "0", "false" ].include?(value)
        raise ArgumentError, "must be a boolean"
      when :date
        value = value.iso8601 if value.is_a?(Date) && !value.is_a?(DateTime)
        raise ArgumentError, "must be an ISO date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      when :datetime
        value = value.to_time.getutc.iso8601(6) if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(DateTime)
        raise ArgumentError, "must be an ISO timestamp" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})?\z/)
        # datetime-local inputs are interpreted in the authenticated context zone.
        zone = ActiveSupport::TimeZone[time_zone]
        zone.iso8601(value).utc
      end
    rescue Date::Error, TypeError
      raise ArgumentError, "is invalid"
    end

    # Schema describes normalized wire values; ordinary form strings are parsed
    # through the same scalar coercion first.
    def json_schema = @json_schema
    def contract = @contract
    def form_partial = @plugin_metadata&.fetch(:form_partial)
    def display_partial(view) = @plugin_metadata&.fetch(view == :index ? :index_partial : :show_partial)
    def choice_options = options[:choices] || choice_values.map { |value| [ value, value ] }
    def choice_values = options[:values] || options[:choices]&.map(&:last) || []

    def scalar_json_schema
      case scalar_type
      when :integer then { "type" => "integer", "minimum" => -(2**63), "maximum" => 2**63 - 1 }
      when :decimal then { "type" => "string", "pattern" => "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$" }
      when :boolean then { "type" => "boolean" }
      when :enum, :select then { "type" => "string", "enum" => choice_values }
      else { "type" => "string", "maxLength" => options[:max_length] }
      end
    end

    private

    def validate_options!
      unless %i[readonly nullable required create edit].all? { |key| [ true, false ].include?(options[key]) } &&
          options[:max_length].is_a?(Integer) && (1..65_536).cover?(options[:max_length]) &&
          (options[:label].nil? || options[:label].is_a?(String) && options[:label].length.between?(1, 200))
        raise ConfigurationError, "Field flags, label or length are invalid"
      end
      return unless %i[enum select].include?(scalar_type)
      if options[:choices]
        unless scalar_type == :select && options[:choices].is_a?(Array) && options[:choices].all? { |pair| pair.is_a?(Array) && pair.size == 2 && pair.all? { |item| item.is_a?(String) && item.length.between?(1, 200) && item.valid_encoding? } }
          raise ConfigurationError, "Select choices must be plain label/string-value pairs"
        end
        raise ConfigurationError, "Use either choices or values" if options[:values]
      end
      values = choice_values
      unless values.is_a?(Array) && values.size.between?(1, 100) && values.uniq.size == values.size && values.all? { |value| value.is_a?(String) && value.length.between?(1, 200) && value.valid_encoding? }
        raise ConfigurationError, "Enum/select requires distinct nonempty string values"
      end
    end

    def immutable_copy(value)
      copy = case value
      when Hash then value.to_h { |key, item| [ key, immutable_copy(item) ] }
      when Array then value.map { |item| immutable_copy(item) }
      when String then String.new(value)
      when Time, ActiveSupport::TimeWithZone, Date then value.dup
      else value
      end
      copy.freeze
    end

    def wire(value)
      case value
      when BigDecimal then value.to_s("F")
      when Time, ActiveSupport::TimeWithZone, DateTime then value.to_time.getutc.iso8601(6)
      when Date then value.iso8601
      else value
      end
    end

    def invoke(method, *args, **keywords)
      klass = @plugin.handler_class
      raise ConfigurationError, "Field type contract changed; reload resource definitions" unless klass.metadata == @plugin_metadata
      ActiveRecord::Base.while_preventing_writes { klass.new.public_send(method, *args, **keywords) }
    rescue ArgumentError
      raise ArgumentError, "is invalid", cause: nil if %i[normalize valid?].include?(method)
      raise ConfigurationError, "Field type hook failed", cause: nil
    rescue ConfigurationError
      raise
    rescue StandardError
      raise ConfigurationError, "Field type hook failed", cause: nil
    end
  end
end
