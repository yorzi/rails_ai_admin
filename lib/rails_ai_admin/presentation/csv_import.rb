# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Creates records from a CSV file, one row at a time through the native
    # create operation: each row has its own policy check, coercion, model
    # validation, transaction and audit event. A check run validates the
    # values without writing anything.
    class CsvImport
      MAX_BYTES = 2 * 1024 * 1024
      MAX_COLUMNS = 200
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

      def template
        @access.authorize_import!
        headers = fields.map do |field|
          header = matching_fields(field.label) == [ field ] ? field.label : field.name.to_s
          %("#{header.gsub('"', '""')}")
        end
        "﻿#{headers.join(',')}\r\n"
      end

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
        columns_hash = @resource.model_class.columns_hash
        results = rows.each_with_index.map do |cells, index|
          input = mapping.each_with_object({}) do |(position, field), values|
            cell = cells[position].to_s
            if !cell.strip.empty?
              values[field.name.to_s] = normalize(field, cell)
            elsif !field.options[:nullable] && (column = columns_hash[field.column]) && !column.null && column.default.nil? && !column.default_function
              values[field.name.to_s] = ""
            end
          end
          run_row(runner, index + 2, input, write)
        end
        ignored = header.each_with_index.reject { |_, position| mapping.key?(position) }.map(&:first).reject(&:blank?)
        Report.new(mapping.values.map(&:label), ignored, results, !write)
      end

      private

      def run_row(runner, number, input, write)
        result = if write
          intent = runner.prepare(context: @context, resource: @resource, operation: :create)
          runner.execute(context: @context, intent_ref: intent.id, input: input, human_confirmed: true, origin: :ui)
        else
          runner.validate_create(context: @context, resource: @resource, input: input)
        end
        RowResult.new(number, result.code, result.errors, result.record_id)
      rescue AccessDenied => error
        RowResult.new(number, error.code, {}, nil)
      end

      # An exact field name can disambiguate colliding normalized labels.
      def map_columns(header)
        used = {}
        header.each_with_index.each_with_object({}) do |(cell, position), mapping|
          matches = matching_fields(cell.to_s)
          raise Invalid, I18n.t("rails_ai_admin.imports.ambiguous_column") if matches.size > 1
          field = matches.first
          next unless field && !used[field.name]
          used[field.name] = true
          mapping[position] = field
        end
      end

      def matching_fields(header)
        @field_names ||= fields.index_by { |field| field.name.to_s }
        exact = @field_names[header.strip]
        return [ exact ] if exact
        @header_aliases ||= fields.flat_map { |field| [ [ key(field.label), field ], [ key(field.name.to_s), field ] ] }
          .group_by(&:first).transform_values { |aliases| aliases.map(&:last).uniq }
        @header_aliases.fetch(key(header), [])
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
        state = :unquoted
        skip_lf = false
        text.each_char do |char|
          if skip_lf
            skip_lf = false
            next if char == "\n"
          end
          if state == :quoted
            if char == '"'
              state = :after_quote
            else
              cell << char
            end
            next
          end

          case char
          when '"'
            raise Invalid, I18n.t("rails_ai_admin.imports.invalid_quote") if state == :unquoted && !cell.empty?
            cell << char if state == :after_quote
            state = :quoted
          when ","
            raise Invalid, I18n.t("rails_ai_admin.imports.too_large") if row.size >= MAX_COLUMNS
            row << cell
            cell = +""
            state = :unquoted
          when "\n", "\r"
            row << cell
            rows << row unless row.all?(&:empty?)
            row, cell = [], +""
            raise Invalid, I18n.t("rails_ai_admin.imports.too_many", limit: @limit) if rows.size > @limit + 1
            state = :unquoted
            skip_lf = char == "\r"
          else
            raise Invalid, I18n.t("rails_ai_admin.imports.invalid_quote") if state == :after_quote
            cell << char
          end
        end
        raise Invalid, I18n.t("rails_ai_admin.imports.unclosed_quote") if state == :quoted
        row << cell
        rows << row unless row.all?(&:empty?)
        rows
      end
    end
  end
end
