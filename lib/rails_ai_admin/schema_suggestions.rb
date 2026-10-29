# frozen_string_literal: true

module RailsAiAdmin
  # Reads schema metadata only. Suggestions never register or expose a field.
  class SchemaSuggestions
    Suggestion = Data.define(:name, :type, :options) do
      def declaration
        suffix = options.map { |key, value| ", #{key}: #{value.inspect}" }.join
        "#{type} :#{name}#{suffix}"
      end
    end
    Report = Data.define(:suggestions, :omitted, :available)
    TYPES = { string: :text, text: :textarea, integer: :integer, decimal: :decimal,
      boolean: :boolean, date: :date, datetime: :datetime, timestamp: :datetime }.freeze
    # Heuristics are a conservative starting point, never a sensitivity proof.
    SENSITIVE = /password|token|secret|credential|ciphertext|encrypted|(?:\A|_)(?:api_key|private_key|access_key|signing_key|otp|ssn|salt|session|digest|role|roles|permission|permissions|security_version)(?:_|\z)|_digest\z/i
    IDENTIFIER = /\A[a-z][a-z0-9_]*\z/

    def self.sensitive?(model, name)
      encrypted = model.respond_to?(:encrypted_attributes) ? model.encrypted_attributes : []
      name.to_s.match?(SENSITIVE) || Array(encrypted&.to_a).map(&:to_s).include?(name.to_s)
    end

    def self.array?(column)
      column.respond_to?(:array) && column.array
    end

    def initialize(model)
      @model = model
    end

    def call
      return unavailable unless @model.is_a?(Class) && @model < ActiveRecord::Base
      columns = @model.columns
      foreign_keys = @model.reflect_on_all_associations(:belongs_to).flat_map { |association| Array(association.foreign_key) }.map(&:to_s)
      foreign_keys.concat(@model.reflect_on_all_associations(:belongs_to).filter_map { |association| association.foreign_type if association.polymorphic? })
      foreign_keys.concat(@model.connection.foreign_keys(@model.table_name).flat_map { |foreign_key| Array(foreign_key.column) }.map(&:to_s))
      omitted = 0
      suggestions = columns.filter_map do |column|
        name = column.name
        next if name == @model.primary_key || name == "id"
        if !name.match?(IDENTIFIER) || [ "lock_version", @model.inheritance_column ].include?(name) || name.end_with?("_id") || foreign_keys.include?(name) || self.class.sensitive?(@model, name) || self.class.array?(column)
          omitted += 1
          next
        end
        type = TYPES[column.type]
        unless type
          omitted += 1
          next
        end
        options = {}
        enum = @model.defined_enums[name]
        if enum && (!enum.keys.all? { |value| value.length <= 100 } || !enum.size.between?(1, 100))
          omitted += 1
          next
        end
        if enum
          type = :enum
          options[:values] = enum.keys
        end
        options[:nullable] = false unless column.null
        options[:max_length] = column.limit if %i[text textarea].include?(type) && column.limit.is_a?(Integer) && column.limit.positive?
        options[:readonly] = true if %w[created_at updated_at].include?(name)
        Suggestion.new(name, type, options.freeze)
      end
      Report.new(suggestions.freeze, omitted, true)
    rescue ActiveRecord::ActiveRecordError
      unavailable
    end

    private

    def unavailable
      Report.new([].freeze, 0, false)
    end
  end
end
