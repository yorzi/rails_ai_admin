# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"
require "json"
require "uri"

module RailsAiAdmin
  # Declares one scalar input/output contract. All presentation and query flags
  # only narrow the permissions returned by the host policy.
  class Field
    TYPES = %i[id text textarea integer decimal boolean date datetime enum select belongs_to time email url password json file files rich_text references].freeze
    # Text-like scalars share text coercion, search and equality filters.
    TEXT_TYPES = %i[text textarea id email url].freeze
    # Never listed, searched, sorted or filtered: a password is write-only and
    # JSON has no stable text or ordering.
    UNQUERYABLE_TYPES = %i[password json file files rich_text references].freeze
    # Fields whose value names records of another resource.
    REFERENCE_TYPES = %i[belongs_to references].freeze
    # A references field holds at most this many keys.
    MAX_REFERENCES = 100
    # Registered types refine plain scalars only.
    PLUGIN_EXCLUDED = %i[belongs_to password json file files rich_text references].freeze
    # Upload fields and their default bound on attached files.
    FILE_TYPES = %i[file files].freeze
    MAX_FILES = 20
    # Rich text is stored HTML; its bound is larger than other text.
    MAX_RICH_TEXT = 1_048_576
    # Default upload bound for a file field: 10 MB.
    MAX_FILE_SIZE = 10 * 1024 * 1024
    CONTENT_TYPE = %r{\A[a-z]+/(?:\*|[a-z0-9][a-z0-9.+-]*)\z}
    TIME_OF_DAY = /\A([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d)(?:\.\d{1,6})?)?\z/
    # A practical address check (Rails' own URI::MailTo pattern), not delivery proof.
    EMAIL = URI::MailTo::EMAIL_REGEXP
    OPTIONS = %i[readonly required nullable values max_length searchable sortable filterable create edit label choices index show hidden help_text tab panel resource foreign_key precision scale accept max_size max_files].freeze
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
    # A registered type's own rejection message; passes through coercion.
    class TypeMessage < ArgumentError; end
    # A coerced password. It is a String for the model's password= writer;
    # input digests store only a keyed hash of it, and it never inspects.
    class Secret < String
      def inspect = "[FILTERED]"
    end
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
      raise ConfigurationError, "Field types cannot refine belongs_to, password or json" if plugin && PLUGIN_EXCLUDED.include?(@scalar_type)
      configure_computation!(compute, depends_on, options)
      defaults = { readonly: @scalar_type == :id, nullable: true, required: false, max_length: 2000, create: true, edit: true, index: true, show: true, hidden: false }
      defaults.merge!(readonly: true, create: false, edit: false, searchable: false, sortable: false) if virtual?
      defaults.merge!(resource: @name.to_s.pluralize.to_sym, foreign_key: "#{@name}_id") if @scalar_type == :belongs_to
      # Listing keys costs a query per row, so lists leave references out.
      defaults.merge!(resource: @name.to_sym, foreign_key: "#{@name.to_s.singularize}_ids", index: false) if @scalar_type == :references
      # Documents and formatted text crowd a list; show pages carry them.
      defaults.merge!(max_length: 65_536, index: false) if @scalar_type == :json
      defaults.merge!(index: false) if @scalar_type == :rich_text
      defaults.merge!(index: false, show: false) if @scalar_type == :password
      defaults.merge!(max_size: MAX_FILE_SIZE) if @scalar_type == :file
      # Attachments cost a query per row, so lists leave files out.
      defaults.merge!(max_size: MAX_FILE_SIZE, max_files: MAX_FILES, index: false) if @scalar_type == :files
      defaults.merge!(max_length: MAX_RICH_TEXT) if @scalar_type == :rich_text
      @options = immutable_copy(defaults.merge(options))
      validate_options!
      validate_association_options!
      validate_query_options!
      @column = (REFERENCE_TYPES.include?(@scalar_type) ? @options[:foreign_key] : @name.to_s).dup.freeze
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
    def plugin? = !@plugin.nil?

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
      when :datetime then format_time(value.in_time_zone(time_zone))
      when :date then value.iso8601
      when :select then choice_options.find { |_, key| key == value }&.first || value.to_s
      when :time then format_time_of_day(value)
      when :json then format_json(value)
      when :password then "—"
      when :rich_text then plain_text(value.to_s)
      when :file then value.respond_to?(:filename) ? "#{value.filename} (#{ActiveSupport::NumberHelper.number_to_human_size(value.byte_size)})" : value.to_s
      when :files then I18n.t(:files, scope: %i[rails_ai_admin fields], count: Array(value).size, default: "#{Array(value).size} files")
      else value.to_s
      end
    end

    # "10 Nov 2026 10:44 UTC" in the context zone (RAA-015); seconds appear
    # only when set. Pages put the exact ISO value in a <time> element.
    def format_time(time)
      time.strftime(time.sec.zero? ? "%-d %b %Y %H:%M %Z" : "%-d %b %Y %H:%M:%S %Z")
    end

    # "14:30", or "14:30:15" when seconds are set. Active Record returns a
    # time column as a Time on 2000-01-01; coerced input is "HH:MM:SS".
    def format_time_of_day(value)
      value = value.strftime("%H:%M:%S") if value.respond_to?(:strftime)
      parts = value.to_s.match(TIME_OF_DAY)
      return value.to_s unless parts
      parts[3].nil? || parts[3] == "00" ? "#{parts[1]}:#{parts[2]}" : "#{parts[1]}:#{parts[2]}:#{parts[3]}"
    end

    # Rich text as plain text, for lists, CSV and the assistant.
    def plain_text(html)
      text = defined?(::ActionText::Content) ? ::ActionText::Content.new(html).to_plain_text : Rails::HTML5::FullSanitizer.new.sanitize(html)
      text.to_s.truncate_bytes(16_000)
    end

    # Indented JSON, cut to the page bound so a large document cannot fail a page.
    def format_json(value)
      value = JSON.parse(value) if value.is_a?(String)
      text = JSON.pretty_generate(value)
      text.bytesize > 16_000 ? "#{text.byteslice(0, 16_000).scrub("")}…" : text
    rescue JSON::ParserError, JSON::GeneratorError
      value.to_s.truncate(16_000)
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
        # Clearing a password would remove the sign-in secret; leave it out instead.
        raise ArgumentError, message(:blank, "cannot be blank") if scalar_type == :password
        raise ArgumentError, message(:blank, "cannot be blank") if strict && (options[:required] || !options[:nullable])
        raise ArgumentError, message(:blank, "cannot be blank") unless options[:nullable]
        return nil
      end
      case scalar_type
      when :belongs_to
        value = value.to_s if value.is_a?(Integer) && value.positive?
        raise ArgumentError, message(:unavailable_choice, "is not an available choice") unless value.is_a?(String) && value.valid_encoding? && value.match?(REFERENCE)
        String.new(value)
      when :text, :textarea, :id, :email, :url, :password, :rich_text
        raise ArgumentError, message(:not_text, "must be text") unless value.is_a?(String)
        raise ArgumentError, message(:too_long, "is too long") if value.length > options[:max_length]
        raise ArgumentError, message(:invalid, "is invalid") unless value.valid_encoding?
        if strict && value.match?(%i[textarea rich_text].include?(scalar_type) ? TEXTAREA_CONTROLS : TEXT_CONTROLS)
          raise ArgumentError, message(:control_characters, "contains control characters")
        end
        if strict && scalar_type == :email && !value.match?(EMAIL)
          raise ArgumentError, message(:not_email, "must be an email address")
        end
        raise ArgumentError, message(:not_url, "must be an http or https address") if strict && scalar_type == :url && !web_address?(value)
        scalar_type == :password ? Secret.new(value) : String.new(value)
      when :time
        value = value.strftime("%H:%M:%S") if value.respond_to?(:strftime) && !value.is_a?(String)
        parts = value.is_a?(String) && value.match(TIME_OF_DAY)
        raise ArgumentError, message(:not_time, "must be a time of day (HH:MM)") unless parts
        "#{parts[1]}:#{parts[2]}:#{parts[3] || '00'}"
      when :file then coerce_file(value)
      when :files then coerce_files(value)
      when :references
        raise ArgumentError, message(:not_list, "must be a list of records") unless value.is_a?(Array) && value.size <= MAX_REFERENCES + 1
        keys = value.map { |item| item.is_a?(Integer) && item.positive? ? item.to_s : item }.reject { |item| item == "" }
        unless keys.all? { |item| item.is_a?(String) && item.valid_encoding? && item.match?(REFERENCE) }
          raise ArgumentError, message(:unavailable_choice, "is not an available choice")
        end
        keys = keys.uniq.sort
        raise ArgumentError, message(:too_many, "can name at most %{count} records", count: MAX_REFERENCES) if keys.size > MAX_REFERENCES
        raise ArgumentError, message(:blank, "cannot be blank") if strict && keys.empty? && options[:required]
        keys.map { |key| String.new(key).freeze }.freeze
      when :json
        value = parse_json(value) if value.is_a?(String)
        raise ArgumentError, message(:not_json, "must be valid JSON") unless json_value?(value)
        raise ArgumentError, message(:too_long, "is too long") if JSON.generate(value).length > options[:max_length]
        value
      when :enum, :select
        raise ArgumentError, message(:not_allowed, "is not an allowed value") unless choice_values.include?(value)
        raise ArgumentError, message(:invalid, "is invalid") unless value.valid_encoding?
        String.new(value)
      when :integer
        raise ArgumentError, message(:not_integer, "must be an integer") unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[+-]?\d+\z/))
        raise ArgumentError, message(:out_of_range, "is out of range") if value.is_a?(String) && value.length > 100
        number = value.is_a?(String) ? Integer(value, 10) : value
        raise ArgumentError, message(:out_of_range, "is out of range") unless (-(2**63)..(2**63 - 1)).cover?(number)
        number
      when :decimal
        raise ArgumentError, message(:not_decimal, "must be a decimal") unless value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/))
        raise ArgumentError, message(:out_of_range, "is out of range") if value.is_a?(String) && value.length > MAX_NUMBER_TEXT
        number = BigDecimal(value.to_s)
        raise ArgumentError, message(:not_finite, "must be finite") unless number.finite?
        check_decimal_limits!(number) if strict
        number
      when :boolean
        return true if [ true, "1", "true" ].include?(value)
        return false if [ false, "0", "false" ].include?(value)
        raise ArgumentError, message(:not_boolean, "must be a boolean")
      when :date
        value = value.iso8601 if value.is_a?(Date) && !value.is_a?(DateTime)
        raise ArgumentError, message(:not_date, "must be an ISO date") unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      when :datetime
        value = value.to_time.getutc.iso8601(6) if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(DateTime)
        parts = value.is_a?(String) && value.match(DATETIME)
        raise ArgumentError, message(:not_timestamp, "must be an ISO timestamp") unless parts
        # Ruby and Active Support roll 2026-02-30 into March (DEP-013); an
        # impossible calendar day or clock time is rejected instead (RAA-010).
        year, month, day, hour, minute, second, offset_hour, offset_minute = parts.captures.map { |part| part&.to_i }
        unless Date.valid_civil?(year, month, day) && hour <= 23 && minute <= 59 && second.to_i <= 59 &&
            offset_hour.to_i <= 23 && offset_minute.to_i <= 59
          raise ArgumentError, message(:invalid_datetime, "is not a valid date and time")
        end
        # datetime-local inputs are interpreted in the authenticated context zone.
        zone = ActiveSupport::TimeZone[time_zone]
        begin
          zone.iso8601(value).utc
        rescue ArgumentError
          raise ArgumentError, message(:invalid_datetime, "is not a valid date and time"), cause: nil
        end
      end
    rescue Date::Error, TypeError
      raise ArgumentError, message(:invalid, "is invalid")
    end

    # Precision and scale come from explicit precision:/scale: options, or else
    # from the declaring resource's decimal column on first use.
    def decimal_limits
      return {} unless scalar_type == :decimal
      explicit = options.slice(:precision, :scale)
      return explicit if explicit.any?
      column_decimal_limits
    end

    # Whether a declared accept list admits this content type ("image/*" works).
    def accepts?(content_type)
      list = options[:accept]
      return true if list.nil?
      list.any? { |pattern| pattern.end_with?("/*") ? content_type.start_with?(pattern.delete_suffix("*")) : content_type == pattern }
    end

    # An absolute http(s) address, the only kind pages turn into links.
    def web_address?(value)
      uri = URI.parse(value)
      %w[http https].include?(uri.scheme&.downcase) && uri.host.present? && !value.match?(/[[:space:]]/)
    rescue URI::Error
      false
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
      when :files then { "type" => "object", "additionalProperties" => false, "properties" => { "add" => { "type" => "array", "items" => { "type" => "string" } }, "remove" => { "type" => "array", "items" => { "type" => "string" } } } }
      when :references then { "type" => "array", "maxItems" => MAX_REFERENCES, "items" => { "type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$" } }
      when :time then { "type" => "string", "pattern" => "^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9](\\.[0-9]{1,6})?)?$" }
      when :url then { "type" => "string", "pattern" => "^[Hh][Tt][Tt][Pp][Ss]?://", "maxLength" => options[:max_length] }
      when :json then { "type" => %w[object array string number boolean] }
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
      # A type may explain a rejection with a short plain message (RAA-011).
      if valid.is_a?(String)
        message = valid.gsub(/[[:cntrl:]]/, " ").squish
        raise ConfigurationError, "Field validation messages must be 1 to 200 characters of plain text" unless message.valid_encoding? && message.length.between?(1, 200)
        raise TypeMessage, message
      end
      raise ConfigurationError, "Field validation must return a boolean or a message" unless [ true, false ].include?(valid)
      raise ArgumentError, message(:invalid, "is invalid") unless valid && @validator.valid?(wire(normalized))
      normalized
    rescue TypeMessage
      raise
    rescue ArgumentError
      raise ArgumentError, message(:invalid, "is invalid"), cause: nil if @plugin
      raise
    end

    # An upload arrives as the signed id of a new, unattached Active Storage
    # blob. Its identified content type and size must fit the declaration.
    # A files change: new uploads to add and attachment ids to remove. A list
    # is never replaced as a whole, so concurrent additions are kept.
    def coerce_files(value)
      value = value.to_h { |key, item| [ key.to_s, item ] } if value.is_a?(Hash)
      unless value.is_a?(Hash) && (value.keys - %w[add remove]).empty? && value.values.all? { |item| item.is_a?(Array) }
        raise ArgumentError, message(:invalid, "is invalid")
      end
      add = Array(value["add"]).map { |item| coerce_file(item) }
      remove = Array(value["remove"]).map { |item| item.is_a?(Integer) && item.positive? ? item.to_s : item }
      raise ArgumentError, message(:unavailable_choice, "is not an available choice") unless remove.all? { |item| item.is_a?(String) && item.match?(REFERENCE) }
      raise ArgumentError, message(:too_many_files, "can hold at most %{count} files", count: options[:max_files]) if add.size > options[:max_files] || remove.size > MAX_REFERENCES
      { "add" => add.uniq.freeze, "remove" => remove.uniq.sort.freeze }.freeze
    end

    def coerce_file(value)
      if value.is_a?(Fields::RejectedUpload)
        raise ArgumentError, message(:file_too_large, "is larger than %{size}", size: ActiveSupport::NumberHelper.number_to_human_size(options[:max_size]))
      end
      raise ConfigurationError, "file fields need Active Storage" unless defined?(::ActiveStorage::Blob)
      raise ArgumentError, message(:invalid, "is invalid") unless value.is_a?(String) && value.valid_encoding? && value.length.between?(1, 1000)
      blob = ::ActiveStorage::Blob.find_signed(value)
      raise ArgumentError, message(:file_unavailable, "is not an available upload") unless blob && !blob.attachments.exists?
      raise ArgumentError, message(:file_too_large, "is larger than %{size}", size: ActiveSupport::NumberHelper.number_to_human_size(options[:max_size])) if blob.byte_size > options[:max_size]
      raise ArgumentError, message(:file_type, "is not an accepted file type") unless accepts?(blob.content_type.to_s)
      String.new(value)
    end

    def parse_json(text)
      raise ArgumentError, message(:too_long, "is too long") if text.length > options[:max_length]
      JSON.parse(text, max_nesting: 32)
    rescue JSON::ParserError, JSON::NestingError
      raise ArgumentError, message(:not_json, "must be valid JSON"), cause: nil
    end

    def json_value?(value, depth = 0)
      return false if depth > 32
      case value
      when Hash then value.all? { |key, item| key.is_a?(String) && key.valid_encoding? && json_value?(item, depth + 1) }
      when Array then value.all? { |item| json_value?(item, depth + 1) }
      when String then value.valid_encoding?
      when Integer, true, false, nil then true
      when Float then value.finite?
      else false
      end
    end

    # Output values keep the historical rule (only non-text "" is blank) so a
    # computation or preview is typed, never reinterpreted.
    def blank_input?(value, strict)
      return true if value.nil?
      return false unless value.is_a?(String)
      return value.empty? && !%i[text textarea].include?(scalar_type) unless strict
      return true if value.empty?
      (TEXT_TYPES + %i[password time json rich_text]).include?(scalar_type) && value.valid_encoding? && value.match?(BLANK)
    end

    # Field input messages are translatable under rails_ai_admin.fields.errors.
    # The English default keeps a missing translation from failing a write.
    def self.error_message(key, default, **values)
      I18n.t(key, scope: %i[rails_ai_admin fields errors], default: default, **values)
    end

    def message(key, default, **values) = self.class.error_message(key, default, **values)

    def check_decimal_limits!(number)
      limits = decimal_limits
      scale, precision = limits[:scale], limits[:precision]
      raise ArgumentError, message(:decimal_places, "must have at most %{count} decimal places", count: scale) if scale && number.scale > scale
      return unless precision
      whole_digits = [ number.exponent, 0 ].max
      raise ArgumentError, message(:out_of_range, "is out of range") if whole_digits > precision - (scale || 0)
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
          options[:max_length].is_a?(Integer) && (1..(scalar_type == :rich_text ? MAX_RICH_TEXT : 65_536)).cover?(options[:max_length]) &&
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

    def validate_query_options!
      if UNQUERYABLE_TYPES.include?(scalar_type) && (options[:searchable] || options[:sortable] || options[:filterable])
        raise ConfigurationError, "#{scalar_type} fields cannot search, sort or filter"
      end
      if scalar_type == :time && (options[:searchable] || options[:filterable])
        raise ConfigurationError, "time fields can sort but cannot search or filter"
      end
      if !FILE_TYPES.include?(scalar_type) && (options.key?(:accept) || options.key?(:max_size))
        raise ConfigurationError, "accept and max_size are file options"
      end
      raise ConfigurationError, "max_files is a files option" if scalar_type != :files && options.key?(:max_files)
      if scalar_type == :files
        raise ConfigurationError, "files max_files must be 1..100" unless options[:max_files].is_a?(Integer) && options[:max_files].between?(1, MAX_REFERENCES)
        raise ConfigurationError, "files fields cannot be required" if options[:required]
      end
      if FILE_TYPES.include?(scalar_type)
        accept, size = options[:accept], options[:max_size]
        unless accept.nil? || accept.is_a?(Array) && accept.size.between?(1, 50) && accept.all? { |type| type.is_a?(String) && type.match?(CONTENT_TYPE) }
          raise ConfigurationError, "file accept must list content types such as image/png or image/*"
        end
        raise ConfigurationError, "file max_size must be a positive Integer of bytes" unless size.is_a?(Integer) && size.between?(1, 2**40)
      end
      if scalar_type == :password && (options[:index] || options[:show] || options[:readonly])
        raise ConfigurationError, "password fields are write-only: no index, show or readonly"
      end
    end

    def validate_association_options!
      if !REFERENCE_TYPES.include?(scalar_type)
        raise ConfigurationError, "resource and foreign_key are belongs_to and references options" if options.key?(:resource) || options.key?(:foreign_key)
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
      raise ArgumentError, message(:invalid, "is invalid"), cause: nil if %i[normalize valid?].include?(method)
      raise ConfigurationError, "Field type hook failed", cause: nil
    rescue ConfigurationError
      raise
    rescue StandardError
      raise ConfigurationError, "Field type hook failed", cause: nil
    end
  end
end
