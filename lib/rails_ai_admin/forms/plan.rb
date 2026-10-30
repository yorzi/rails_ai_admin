# frozen_string_literal: true

module RailsAiAdmin
  module Forms
    # Presentation-only snapshots; callers supply currently authorized fields.
    # No record, denied value, query or persistence lives in this plan.
    class Plan
      Entry = Data.define(:field, :editable, :value)
      Panel = Data.define(:label, :entries)
      Tab = Data.define(:label, :panels)
      MAX_FIELDS = 128
      MAX_TABS = 8
      MAX_PANELS = 16
      MAX_VALUE_BYTES = 262_144
      MAX_BYTES = 1_048_576
      attr_reader :tabs, :entries

      def initialize(fields:, values:, readonly_fields: [], readonly_values: {}, order: nil)
        unless values.is_a?(Hash) && readonly_values.is_a?(Hash)
          raise ConfigurationError, "Form values must be scalar maps"
        end
        writable = fields.reject(&:hidden?).index_by(&:name)
        readable = readonly_fields.reject(&:hidden?).index_by(&:name).except(*writable.keys)
        @bytes = 0
        @entries = (Array(order) + fields + readonly_fields).uniq(&:name).filter_map do |field|
          next unless writable.key?(field.name) || readable.key?(field.name)
          editable = writable.key?(field.name)
          source = editable ? values : readonly_values
          value = source.key?(field.name.to_s) ? source[field.name.to_s] : source[field.name]
          Entry.new(field, editable, scalar(value))
        end.freeze
        raise ConfigurationError, "Form field bound exceeded" if @entries.size > MAX_FIELDS
        @tabbed = @entries.any? { |entry| entry.field.options[:tab] }
        groups = @entries.group_by { |entry| entry.field.options[:tab] || (@tabbed ? "Details" : nil) }
        raise ConfigurationError, "Form tab bound exceeded" if groups.size > MAX_TABS
        @tabs = groups.map do |label, entries|
          panels = entries.group_by { |entry| entry.field.options[:panel] }
          raise ConfigurationError, "Form panel bound exceeded" if panels.size > MAX_PANELS
          Tab.new(label, panels.map { |title, items| Panel.new(title, items.freeze) }.freeze)
        end.freeze
        @tabbed &&= @tabs.size > 1
        freeze
      end

      def tabbed? = @tabbed

      private

      def scalar(value)
        copy = case value
        when nil, true, false, Integer then value
        when String then String.new(value).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        when BigDecimal
          raise ConfigurationError, "Form decimals must be finite" unless value.finite?
          value
        when Time, ActiveSupport::TimeWithZone, DateTime then value.to_time.getutc
        when Date then Date.iso8601(value.iso8601)
        else raise ConfigurationError, "Form values require supported scalars"
        end
        bytes = JSON.generate(InputSchema.canonical(copy)).bytesize
        @bytes += bytes
        raise ConfigurationError, "Form value bound exceeded" if bytes > MAX_VALUE_BYTES || @bytes > MAX_BYTES
        copy.freeze
      end
    end
  end
end
