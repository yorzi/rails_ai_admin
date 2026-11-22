# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # The current list (search, list tab, filters and sort) as CSV, through
    # the same grants as the pages: rows from the index relation and each
    # record's show grant, columns and values from its read grant.
    class CsvExport
      BATCH = 500
      # A spreadsheet runs a cell that starts with these as a formula
      # (CSV injection); such cells get a leading apostrophe.
      FORMULA = /\A(?:[=+\-@\t\r\n]|[[:space:]]+[=+\-@])/
      # Number and time text is produced by coercion and cannot be a formula.
      NUMERIC = %i[integer decimal date datetime time].freeze
      Result = Data.define(:body, :rows, :fields, :too_many)

      def initialize(context, resource, limit: RailsAiAdmin.configuration.export_limit)
        @context, @resource, @limit = context, resource, limit
        @access = Authorization::Access.new(context, resource)
      end

      def call(search: nil, sort: nil, direction: "asc", scope: nil, filters: nil)
        @access.authorize_export!
        relation = Queries::List.new(@context, @resource).relation(search: search, sort: sort, direction: direction, scope: scope, filters: filters)
        return Result.new(nil, 0, [], true) if relation.except(:order).limit(@limit + 1).count > @limit
        fields = @access.fields(:read, nil, view: :show)
        references = Fields::Association.new(@context, @resource)
        lines = [ line(fields.map(&:label)) ]
        # Preload associations for visible columns once per batch instead of per row.
        model = @resource.model_class
        preloads = fields.filter_map do |field|
          case field.scalar_type
          when :references then field.name if model.reflect_on_association(field.name)
          when :file then { "#{field.column}_attachment": :blob } if model.reflect_on_association(:"#{field.column}_attachment")
          when :rich_text then :"rich_text_#{field.column}" if model.reflect_on_association(:"rich_text_#{field.column}")
          end
        end
        relation = relation.preload(*preloads) if preloads.any?
        rows = 0
        offset = 0
        loop do
          remaining = @limit - offset
          break if remaining <= 0
          records = relation.offset(offset).limit([ BATCH, remaining ].min).to_a
          break if records.empty?
          offset += records.size
          fields.select { |field| field.scalar_type == :belongs_to }.each do |field|
            ids = records.filter_map { |record| record.has_attribute?(field.column) ? record.read_attribute(field.column)&.to_s : nil }.uniq
            ids.each_slice(Fields::Association::MAX_BATCH) { |slice| references.prime(field, slice) }
          end
          fields.select { |field| field.scalar_type == :references }.each do |field|
            ids = records.flat_map { |record| Array(record.public_send(field.column)).map(&:to_s) }.uniq
            ids.each_slice(Fields::Association::MAX_BATCH) { |slice| references.prime(field, slice) }
          end
          records.each do |record|
            values = @access.project(record, view: :show)
            lines << line(fields.map { |field| values.key?(field.name.to_s) ? cell(field, values[field.name.to_s], references) : "" })
            rows += 1
          rescue AccessDenied
            # Left out like an unavailable row on the list page (RAA-001).
            next
          end
          break if records.size < BATCH || offset >= @limit
        end
        # The byte order mark lets spreadsheet programs read UTF-8.
        Result.new("﻿#{lines.join}", rows, fields.map { |field| field.name.to_s }, false)
      end

      private

      def cell(field, value, references)
        return "" if value.nil?
        text = if field.plugin?
          field.format(value, time_zone: @context.time_zone)
        else
          case field.scalar_type
          when :date then value.iso8601
          when :datetime then value.in_time_zone(@context.time_zone).iso8601
          when :decimal then field.format_decimal(value)
          when :json then JSON.generate(value)
          when :file then value.filename
          when :files then Array(value).map(&:filename).join("; ")
          when :references
            Array(value).map { |id| references.reference(field, id).label.to_s }.join("; ")
          when :belongs_to then references.reference(field, value.to_s).label.to_s
          else field.format(value, time_zone: @context.time_zone)
          end
        end
        text = text.to_s
        (field.plugin? || !NUMERIC.include?(field.scalar_type)) && text.match?(FORMULA) ? "'#{text}" : text
      end

      def line(cells)
        "#{cells.map { |cell| %("#{cell.to_s.gsub('"', '""')}") }.join(',')}\r\n"
      end
    end
  end
end
