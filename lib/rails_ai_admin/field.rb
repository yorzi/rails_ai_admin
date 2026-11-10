# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module RailsAiAdmin
  # Declares one scalar input/output contract. All presentation and query flags
  # only narrow the permissions returned by the host policy.
  class Field
    TYPES = %i[id text textarea integer decimal boolean date datetime enum select belongs_to].freeze
    OPTIONS = %i[readonly required nullable values max_length searchable sortable filterable create edit label choices index show hidden help_text tab panel resource foreign_key precision scale].freeze
    # A belongs_to value is the target's opaque primary-key text, never a record.
    REFERENCE = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z/
    NAME = /\A[a-z][a-z0-9_]*\z/
    # Input text that is empty or only whitespace is blank (RAA-002/003).
    BLANK = /\A[[:space:]]*\z/
    # NUL and other C0 controls are never accepted in single-line text; a
    # textarea additionally admits tab, line feed and carriage return (RAA-016).
    TEXT_CONTROLS = /[\x00-\x1F\x7F]/
    TEXTAREA_CONTROLS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
    DATETIME = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(?:Z|[+-](\d{2}):(\d{2}))?\z/
    # Upper bound for decimal wire text, matching the integer bound.
    MAX_NUMBER_TEXT = 100
    # Typed list filter operators. Text-like values only support exact equality;
    # contains/prefix matching stays with search.
    FILTER_OPERATORS = %i[eq gte lte].freeze
    RANGE_TYPES = %i[integer decimal date datetime].freeze
    Descriptor = Data.define(:name, :type, :scalar_type, :options, :scalar_json_schema)
    attr_reader :name, :type, :scalar_type, :options, :dependencies, :filter_operators, :column

    # source is the declaring Resource class. It is consulted lazily, on the
    # first decimal coercion, for column precision and scale; never at boot.
    def initialize(name, type:, plugin: nil, compute: nil, depends_on: nil, source: nil, **options)
      @name, @type = name.to_sym, type.to_sym
      @plugin = plugin
      @source = source
      @plugin_metadata = plugin && immutable_copy(plugin.metadata)
      @scalar_type = @plugin_metadata ? @plugin_metadata.fetch(:scalar) : @type
      raise ConfigurationError, "Invalid field name" unless @name.to_s.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ConfigurationError, "Unknown field type" unless TYPES.include?(@scalar_type) && (plugin || TYPES.include?(@type))
      raise ConfigurationError, "Unknown field option" unless (options.keys - OPTIONS).empty?
      raise ConfigurationError, "Field types cannot refine belongs_to" if plugin && @scalar_type == :belongs_to
      configure_computation!(compute, depends_on, options)
      defaults = { readonly: @scalar_type == :id, nullable: true, required: false, max_length: 2000, create: true, edit: true, index: true, show: true, hidden: false }
      defaults.merge!(readonly: true, create: false, edit: false, searchable: false, sortable: false) if virtual?
      defaults.merge!(resource: @name.to_s.pluralize.to_sym, foreign_key: "#{@name}_id") if @scalar_type == :belongs_to
      @options = immutable_copy(defaults.merge(options))
      validate_options!
      validate_association_options!
      @column = (@scalar_type == :belongs_to ? @options[:foreign_key] : @name.to_s).dup.freeze
      @filter_operators = resolve_filter_operators
      @descriptor = Descriptor.new(@name, @type, @scalar_type, @options, immutable_copy(scalar_json_schema))
      if @plugin
        constraints = invoke(:schema, field: @descriptor)
        schema, @validator = Fields::ScalarSchema.compile(@descriptor.scalar_json_schema, constraints)
      else
        schema = @descriptor.scalar_json_schema
      end
      @json_schema = immutable_copy(@options[:nullable] ? { "anyOf" => [ schema, { "type" => "null" } ] } : schema)
      contract = { name: @name, type: @type, scalar: @scalar_type, options: @options, plugin: @plugin_metadata, schema: @json_schema }
      contract[:computation] = { **@computation_metadata, dependencies: @dependencies } if virtual?
      @contract = immutable_copy(contract)
      freeze
    end

    def virtual? = !@computation.nil?

    def compute(values, time_zone:)
      klass = @computation.handler_class
      raise ConfigurationError, "Computation changed; reload resource definitions" unless klass.metadata == @computation_metadata
      result = ActiveRecord::Base.while_preventing_writes { klass.new.call(values, field: @descriptor, time_zone: time_zone) }
      coerce_output(result, time_zone: time_zone)
    rescue ConfigurationError
      raise
    rescue StandardError
      raise ConfigurationError, "Computed field failed its scalar contract", cause: nil
    end

    def label
      options[:label] || name.to_s.humanize
    end

    def writable?(operation)
      !hidden? && !options[:readonly] && options[operation.to_sym == :create ? :create : :edit]
    end

    def hidden? = options[:hidden]

    def visible_on?(view)
      return false if hidden?
      raise ConfigurationError, "Unknown field presentation view" unless %i[index show create edit].include?(view)
      options.fetch(view)
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
      when :decimal then format_decimal(value)
      when :datetime then value.in_time_zone(time_zone).iso8601(6)
      when :date then value.iso8601
      when :select then choice_options.find { |_, key| key == value }&.first || value.to_s
      else value.to_s
      end
    end

    # Decimal text padded to the declared or column scale ("10.50", not
    # "10.5"). It never rounds: a stored value with more digits keeps them, so
    # a form prefilled from it submits the same number back (RAA-014).
    def format_decimal(value)
      number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      return number.to_s("F") unless number.finite?
      scale = decimal_limits[:scale]
      return number.to_s("F") unless scale
      whole, fraction = number.to_s("F").split(".")
      fraction = fraction.to_s.delete_suffix("0") if fraction == "0"
      fraction = fraction.to_s.ljust(scale, "0")
      fraction.empty? ? whole : "#{whole}.#{fraction}"
    rescue ArgumentError, TypeError
      value.to_s
    end

    # Coerces form or JSON input values, preserving false, zero and null. Input
    # is strict: blank text, control characters, out-of-scale decimals and
    # impossible calendar dates are rejected with a field message.
    def coerce(value, time_zone: "UTC") = coerce_value(value, time_zone, strict: true)

    # Internal: types a value produced by host code (a computation or a
    # preflight preview). It checks the scalar type only, so a handler result is
    # never rejected by the input-only rules above.
    def coerce_output(value, time_zone: "UTC") = coerce_value(value, time_zone, strict: false)

    def coerce_scalar(value, time_zone: "UTC", strict: true)
      if blank_input?(value, strict)
        raise ArgumentError, "cannot be blank" if strict && (options[:required] || !options[:nullable])
        raise ArgumentError, "cannot be blank" unless options[:nullable]
        return nil
      end
      case scalar_type
      when :belongs_to
        value = value.to_s if value.is_a?(Integer) && value.positive?
        raise ArgumentError, "is not an available choice" unless value.is_a?(String) && value.valid_encoding? && value.match?(REFERENCE)
        String.new(value)
      when :text, :textarea, :id
        raise ArgumentError, "must be text" unless value.is_a?(String)
        raise ArgumentError, "is too long" if value.length > options[:max_length]
        raise ArgumentError, "is invalid" unless value.valid_encoding?
        if strict && value.match?(scalar_type == :textarea ? TEXTAREA_CONTROLS : TEXT_CONTROLS)
          raise ArgumentError, "contains control characters"
        end
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
        raise ArgumentError, "is out of range" if value.is_a?(String) && value.length > MAX_NUMBER_TEXT
        number = BigDecimal(value.to_s)
        raise ArgumentError, "must be finite" unless number.finite?
        check_decimal_limits!(number) if strict
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
        parts = value.is_a?(String) && value.match(DATETIME)
        raise ArgumentError, "must be an ISO timestamp" unless parts
        # Ruby and Active Support roll 2026-02-30 into March (DEP-013); an
        # impossible calendar day or clock time is rejected instead (RAA-010).
        year, month, day, hour, minute, second, offset_hour, offset_minute = parts.captures.map { |part| part&.to_i }
        unless Date.valid_civil?(year, month, day) && hour <= 23 && minute <= 59 && second.to_i <= 59 &&
            offset_hour.to_i <= 23 && offset_minute.to_i <= 59
          raise ArgumentError, "is not a valid date and time"
        end
        # datetime-local inputs are interpreted in the authenticated context zone.
        zone = ActiveSupport::TimeZone[time_zone]
        begin
          zone.iso8601(value).utc
        rescue ArgumentError
          raise ArgumentError, "is not a valid date and time", cause: nil
        end
      end
    rescue Date::Error, TypeError
      raise ArgumentError, "is invalid"
    end

    # Precision and scale come from explicit precision:/scale: options, or else
    # from the declaring resource's decimal column on first use.
    def decimal_limits
      return {} unless scalar_type == :decimal
      explicit = options.slice(:precision, :scale)
      return explicit if explicit.any?
      column_decimal_limits
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
      when :decimal then { "type" => "string", "pattern" => decimal_pattern }
      when :boolean then { "type" => "boolean" }
      when :enum, :select then { "type" => "string", "enum" => choice_values }
      when :belongs_to then { "type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$" }
      else { "type" => "string", "maxLength" => options[:max_length] }
      end
    end

    private

    def coerce_value(value, time_zone, strict:)
      typed = coerce_scalar(value, time_zone: time_zone, strict: strict)
      return typed unless @plugin && !typed.nil?
      normalized = invoke(:normalize, immutable_copy(typed), field: @descriptor, time_zone: time_zone)
      normalized = coerce_scalar(wire(normalized), time_zone: time_zone, strict: strict)
      repeated = invoke(:normalize, immutable_copy(normalized), field: @descriptor, time_zone: time_zone)
      repeated = coerce_scalar(wire(repeated), time_zone: time_zone, strict: strict)
      raise ConfigurationError, "Field normalization must be idempotent" unless normalized == repeated
      valid = invoke(:valid?, immutable_copy(normalized), field: @descriptor, time_zone: time_zone)
      raise ConfigurationError, "Field validation must return a boolean" unless [ true, false ].include?(valid)
      raise ArgumentError, "is invalid" unless valid && @validator.valid?(wire(normalized))
      normalized
    rescue ArgumentError
      raise ArgumentError, "is invalid", cause: nil if @plugin
      raise
    end

    # Output values keep the historical rule (only non-text "" is blank) so a
    # computation or preview is typed, never reinterpreted.
    def blank_input?(value, strict)
      return true if value.nil?
      return false unless value.is_a?(String)
      return value.empty? && !%i[text textarea].include?(scalar_type) unless strict
      return true if value.empty?
      %i[text textarea id].include?(scalar_type) && value.valid_encoding? && value.match?(BLANK)
    end

    def check_decimal_limits!(number)
      limits = decimal_limits
      scale, precision = limits[:scale], limits[:precision]
      raise ArgumentError, "must have at most #{scale} decimal places" if scale && number.scale > scale
      return unless precision
      whole_digits = [ number.exponent, 0 ].max
      raise ArgumentError, "is out of range" if whole_digits > precision - (scale || 0)
    end

    def column_decimal_limits
      return {} if virtual? || !@source.respond_to?(:model_class)
      column = @source.model_class.columns_hash[@column]
      return {} unless column&.type == :decimal
      limits = { precision: column.precision, scale: column.scale }.compact
      limits.delete(:precision) unless limits[:precision].is_a?(Integer) && limits[:precision].positive?
      limits.delete(:scale) unless limits[:scale].is_a?(Integer) && limits[:scale] >= 0
      limits
    rescue ActiveRecord::ActiveRecordError, ConfigurationError, NameError
      {}
    end

    def decimal_pattern
      precision, scale = options[:precision], options[:scale]
      whole = precision ? (precision - scale.to_i).then { |digits| digits.zero? ? "0*" : "0*[0-9]{1,#{digits}}" } : "[0-9]+"
      fraction = scale ? (scale.zero? ? "(?:\\.0*)?" : "(?:\\.[0-9]{0,#{scale}}0*)?") : "(?:\\.[0-9]*)?"
      bare = scale ? (scale.zero? ? "\\.0+" : "\\.[0-9]{1,#{scale}}0*") : "\\.[0-9]+"
      "^[+-]?(?:#{whole}#{fraction}|#{bare})$"
    end

    def configure_computation!(handler, dependencies, options)
      @dependencies = [].freeze
      return if handler.nil? && dependencies.nil?
      unless handler.is_a?(String) && handler.length <= 200 && handler.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) &&
          dependencies.is_a?(Array) && dependencies.size.between?(1, Fields::DependencyGraph::MAX_DEPENDENCIES) &&
          dependencies.all? { |name| (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(/\A[a-z][a-z0-9_]*\z/) }
        raise ConfigurationError, "Virtual fields require a computation class name and bounded declared dependencies"
      end
      @dependencies = dependencies.map(&:to_sym).freeze
      raise ConfigurationError, "Computed dependencies must be distinct" unless @dependencies.uniq.size == @dependencies.size
      if options.any? { |key, value| %i[readonly].include?(key) && value != true || %i[searchable sortable filterable].include?(key) && value != false }
        raise ConfigurationError, "Virtual fields are readonly and cannot search, sort or filter"
      end
      @computation = Fields::Computation::Definition.new(String.new(handler).freeze)
      @computation_metadata = immutable_copy(@computation.metadata)
    end

    def validate_options!
      unless %i[readonly nullable required create edit index show hidden].all? { |key| [ true, false ].include?(options[key]) } &&
          options[:max_length].is_a?(Integer) && (1..65_536).cover?(options[:max_length]) &&
          (options[:label].nil? || options[:label].is_a?(String) && options[:label].length.between?(1, 200) && options[:label].valid_encoding?)
        raise ConfigurationError, "Field flags, label or length are invalid"
      end
      precision, scale = options[:precision], options[:scale]
      if !precision.nil? || !scale.nil?
        unless scalar_type == :decimal && (precision.nil? || precision.is_a?(Integer) && precision.between?(1, 1000)) &&
            (scale.nil? || scale.is_a?(Integer) && scale.between?(0, precision || 1000))
          raise ConfigurationError, "precision and scale are decimal options with 1..1000 digits and 0 <= scale <= precision"
        end
      end
      { help_text: 500, tab: 80, panel: 80 }.each do |key, limit|
        value = options[key]
        unless value.nil? || value.is_a?(String) && value.valid_encoding? && value.length.between?(1, limit)
          raise ConfigurationError, "Field presentation text must be bounded plain text"
        end
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

    def validate_association_options!
      if scalar_type != :belongs_to
        raise ConfigurationError, "resource and foreign_key are belongs_to options" if options.key?(:resource) || options.key?(:foreign_key)
        return
      end
      resource, foreign_key = options[:resource], options[:foreign_key]
      unless (resource.is_a?(Symbol) || resource.is_a?(String)) && resource.to_s.match?(NAME) && resource.to_s.length <= 100 &&
          foreign_key.is_a?(String) && foreign_key.match?(NAME) && foreign_key.length <= 100 && foreign_key != name.to_s
        raise ConfigurationError, "belongs_to needs a registry key resource and a distinct foreign_key column name"
      end
      # Association search, sort and labels-as-filters need registered joins (LIST-019).
      if options[:searchable] || options[:sortable]
        raise ConfigurationError, "belongs_to fields cannot search or sort yet; filter by the referenced record instead"
      end
    end

    # filterable: true selects type defaults; an Array narrows to allowed operators.
    def resolve_filter_operators
      value = options[:filterable]
      return [].freeze if value.nil? || value == false
      allowed = RANGE_TYPES.include?(scalar_type) ? FILTER_OPERATORS : %i[eq]
      return (RANGE_TYPES.include?(scalar_type) ? %i[gte lte] : %i[eq]).freeze if value == true
      unless value.is_a?(Array) && value.any? && value.all? { |operator| operator.is_a?(Symbol) } && value.uniq.size == value.size && (value - allowed).empty?
        raise ConfigurationError, "Field filterable must be true, false or distinct operators from #{allowed.join(', ')}"
      end
      FILTER_OPERATORS.select { |operator| value.include?(operator) }.freeze
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
