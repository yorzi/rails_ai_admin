# frozen_string_literal: true

module RailsAiAdmin
  module Queries
    # Bounded, permission-aware scalar index query. No SQL expressions enter it.
    class List
      Page = Data.define(:records, :number, :has_next)
      PAGE_SIZE = 25

      def initialize(context, resource)
        @access = Authorization::Access.new(context, resource)
        @resource = resource
      end

      def call(search: nil, sort: nil, direction: "asc", page: "1")
        @access.authorize!(:index)
        raise AccessDenied, "INVALID_QUERY" unless page.to_s.match?(/\A[1-9]\d{0,3}\z/) && page.to_i <= 1000
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        relation = @access.relation
        if search.present?
          raise AccessDenied, "INVALID_QUERY" unless search.is_a?(String) && search.length <= 200
          fields = @access.fields(:search)
          raise AccessDenied, "INVALID_QUERY" if fields.empty?
          predicates = fields.map do |field|
            term = ActiveRecord::Base.sanitize_sql_like(search)
            pattern = case field.options[:searchable]
            when :exact then term
            when :contains then "%#{term}%"
            else "#{term}%"
            end
            @resource.model_class.arel_table[field.name].matches(pattern, "\\")
          end
          relation = relation.where(predicates.reduce(&:or))
        end
        table = @resource.model_class.arel_table
        primary = @resource.model_class.primary_key
        if sort.present?
          field = @access.fields(:sort).find { |entry| entry.name.to_s == sort }
          raise AccessDenied, "INVALID_QUERY" unless field
          relation = relation.reorder(table[field.name].public_send(direction))
          relation = relation.order(table[primary].asc) unless field.name.to_s == primary
        else
          relation = relation.reorder(table[primary].asc)
        end
        records = relation.offset((page.to_i - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
        Page.new(records: records.first(PAGE_SIZE), number: page.to_i, has_next: records.size > PAGE_SIZE)
      end
    end
  end
end
