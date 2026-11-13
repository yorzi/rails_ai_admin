# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Creates records from a CSV file, one row at a time through the native
    # create operation: each row has its own policy check, coercion, model
    # validation, transaction and audit event. A check run validates the
    # values without writing anything.
    class CsvImport
      MAX_BYTES = 2 * 1024 * 1024
      # Types a CSV cell can carry. Files, passwords and lists are left out.
      TYPES = %i[text textarea integer decimal boolean date datetime time enum select email url json belongs_to rich_text].freeze
      TRUE_WORDS = %w[true yes y 1].freeze
      FALSE_WORDS = %w[false no n 0].freeze
      RowResult = Data.define(:number, :code, :errors, :record_id)
      Report = Data.define(:columns, :ignored, :rows, :checked) do
        def created = rows.count { |row| row.code == "OK" && row.record_id }
        def valid = rows.count { |row| row.code == "OK" }
        def failed = rows.reject { |row| row.code == "OK" }
      end

      class Invalid < StandardError; end

      def initialize(context, resource, limit: RailsAiAdmin.configuration.import_limit)
        @context, @resource, @limit = context, resource, limit
        @access = Authorization::Access.new(context, resource)
      end

      # Fields a file may fill: writable on create and representable as text.
      def fields
        @fields ||= @access.fields(:write, @access.relation.new, operation: :create).select { |field| TYPES.include?(field.scalar_type) && !field.plugin? }
      end

      def template = "﻿#{fields.map { |field| %("#{field.label.gsub('"', '""')}") }.join(',')}\r\n"

      def call(text, write:)
        @access.authorize_import!
        raise Invalid, I18n.t("rails_ai_admin.imports.too_large") if text.bytesize > MAX_BYTES
        rows = parse(text.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿"))
        header = rows.shift
        raise Invalid, I18n.t("rails_ai_admin.imports.empty") if header.nil? || rows.empty?
        raise Invalid, I18n.t("rails_ai_admin.imports.too_many", limit: @limit) if rows.size > @limit
        mapping = map_columns(header)
        raise Invalid, I18n.t("rails_ai_admin.imports.no_columns") if mapping.empty?
        runner = Operations::Runner.new
        results = rows.each_with_index.map do |cells, index|
          input = mapping.each_with_object({}) do |(position, field), values|
            cell = cells[position].to_s
            values[field.name.to_s] = normalize(field, cell) unless cell.strip.empty?
          end
          run_row(runner, index + 2, input, write)
        end
        ignored = header.each_with_index.reject { |_, position| mapping.key?(position) }.map(&:first).reject(&:blank?)
        Report.new(mapping.values.map(&:label), ignored, results, !write)
      end

      private

      def run_row(runner, number, input, write)
        if write
          intent = runner.prepare(context: @context, resource: @resource, operation: :create)
          result = runner.execute(context: @context, intent_ref: intent.id, input: input, human_confirmed: true, origin: :ui)
          RowResult.new(number, result.code, result.errors || {}, result.success? ? result.record_id : nil)
        else
          result = runner.preview(context: @context, resource: @resource, operation: :create, input: input)
          result.is_a?(Operations::Result) ? RowResult.new(number, result.code, result.errors || {}, nil) : RowResult.new(number, "OK", {}, nil)
        end
      rescue AccessDenied => error
        RowResult.new(number, error.code, {}, nil)
      end

      # Header cells match a field's label or name, ignoring case and spaces.
      def map_columns(header)
        names = fields.flat_map { |field| [ [ key(field.label), field ], [ key(field.name.to_s), field ] ] }.to_h
        used = {}
        header.each_with_index.each_with_object({}) do |(cell, position), mapping|
          field = names[key(cell.to_s)]
          next unless field && !used[field.name]
          used[field.name] = true
          mapping[position] = field
        end
      end

      def key(text) = text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[\s_]+/, " ").strip

      # Export writes readable text; import reads it back where that is exact.
      def normalize(field, cell)
        case field.scalar_type
        when :boolean
          word = cell.strip.downcase
          localized = { I18n.t("rails_ai_admin.fields.yes").downcase => "true", I18n.t("rails_ai_admin.fields.no").downcase => "false" }
          return localized[word] if localized.key?(word)
          TRUE_WORDS.include?(word) ? "true" : FALSE_WORDS.include?(word) ? "false" : cell
        when :select then field.choice_options.find { |label, _| label == cell }&.last || cell
        when :integer, :decimal, :date, :datetime, :time, :belongs_to then cell.strip
        else cell
        end
      end

      # RFC 4180: quoted cells may hold commas, quotes ("") and line breaks.
      def parse(text)
        raise Invalid, I18n.t("rails_ai_admin.imports.not_utf8") unless text.valid_encoding?
        rows, row, cell = [], [], +""
        quoted = false
        index = 0
        while index < text.length
          char = text[index]
          if quoted
            if char == '"'
              if text[index + 1] == '"'
                cell << '"'
                index += 1
              else
                quoted = false
              end
            else
              cell << char
            end
          elsif char == '"' && cell.empty?
            quoted = true
          elsif char == ","
            row << cell
            cell = +""
          elsif char == "\n" || char == "\r"
            index += 1 if char == "\r" && text[index + 1] == "\n"
            row << cell
            rows << row unless row.all?(&:empty?)
            row, cell = [], +""
            raise Invalid, I18n.t("rails_ai_admin.imports.too_many", limit: @limit) if rows.size > @limit + 1
          else
            cell << char
          end
          index += 1
        end
        raise Invalid, I18n.t("rails_ai_admin.imports.unclosed_quote") if quoted
        row << cell
        rows << row unless row.all?(&:empty?)
        rows
      end
    end
  end
end
