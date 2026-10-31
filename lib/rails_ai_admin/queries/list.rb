# frozen_string_literal: true

module RailsAiAdmin
  module Queries
    # Bounded, permission-aware scalar index query. No SQL expressions enter it.
    class List
      # scope is the applied named scope's name, or nil for the policy relation.
      Page = Data.define(:records, :number, :has_next, :scope)
      PAGE_SIZE = 25

      def initialize(context, resource)
        @access = Authorization::Access.new(context, resource)
        @resource = resource
      end

      # scope: nil uses the declared default when it is currently granted.
      # A named scope must be declared and granted; it is never discarded here.
      def call(search: nil, sort: nil, direction: "asc", page: "1", recover_empty_page: false, scope: nil)
        @access.authorize!(:index)
        unless (page.is_a?(String) || page.is_a?(Integer)) && page.to_s.valid_encoding? && page.to_s.ascii_only? && page.to_s.match?(/\A[1-9]\d{0,3}\z/) && page.to_i <= 1000
          raise AccessDenied, "INVALID_QUERY"
        end
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        unless search.nil? || search.is_a?(String) && search.valid_encoding? && (search.encoding == Encoding::UTF_8 || search.ascii_only?) && search.length <= 200 && !search.match?(/[\x00-\x1f\x7f]/)
          raise AccessDenied, "INVALID_QUERY"
        end
        unless scope.nil? || scope.is_a?(String) && scope.valid_encoding? && scope.ascii_only? && scope.match?(NamedScope::NAME)
          raise AccessDenied, "INVALID_QUERY"
        end
        granted = @access.named_scopes
        named = scope.nil? ? granted.find(&:default?) : granted.find { |definition| definition.name.to_s == scope }
        raise AccessDenied, "INVALID_QUERY" if scope && !named
        relation = @access.relation
        relation = named.apply(relation) if named
        if search.present?
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
        number = page.to_i
        if recover_empty_page && records.empty? && number > 1
          count = relation.except(:order).limit(number * PAGE_SIZE).count
          number = [ 1, (count - 1).div(PAGE_SIZE) + 1 ].max
          records = relation.offset((number - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
        end
        Page.new(records: records.first(PAGE_SIZE), number: number, has_next: records.size > PAGE_SIZE, scope: named&.name&.to_s)
      end
    end
  end
end
