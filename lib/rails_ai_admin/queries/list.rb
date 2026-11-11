# frozen_string_literal: true

module RailsAiAdmin
  module Queries
    # Bounded, permission-aware scalar index query. No SQL expressions enter it.
    class List
      # scope is the applied named scope's name, or nil for the policy relation.
      # sort/direction describe the applied order (nil sort: primary key only).
      # count is nil unless the resource opts in; count_capped marks COUNT_LIMIT.
      Page = Data.define(:records, :number, :has_next, :scope, :sort, :direction, :page_size, :count, :count_capped)
      # Default page size; resources may choose 1..100 through `index`.
      PAGE_SIZE = 25
      COUNT_LIMIT = Presentation::IndexSettings::COUNT_LIMIT
      MAX_FILTER_CONDITIONS = 20
      FILTER_VALUE = ->(value) { value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) && value.length.between?(1, 200) && !value.match?(/[\x00-\x1f\x7f]/) }
      AREL_PREDICATES = { "eq" => :eq, "gte" => :gteq, "lte" => :lteq }.freeze

      def initialize(context, resource)
        @access = Authorization::Access.new(context, resource)
        @resource = resource
      end

      # scope: nil uses the declared default when it is currently granted;
      # NamedScope::NONE applies no named scope at all.
      # A named scope must be declared and granted; it is never discarded here.
      # filters: { "field" => { "eq" | "gte" | "lte" => "wire string" } }, ANDed.
      # Every field needs a current :filter grant and a declared operator.
      def call(search: nil, sort: nil, direction: "asc", page: "1", recover_empty_page: false, scope: nil, filters: nil, page_size: nil, offset: nil)
        @access.authorize!(:index)
        unless (page.is_a?(String) || page.is_a?(Integer)) && page.to_s.valid_encoding? && page.to_s.ascii_only? && page.to_s.match?(/\A[1-9]\d{0,3}\z/) && page.to_i <= 1000
          raise AccessDenied, "INVALID_QUERY"
        end
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters)
        settings = @resource.index
        size = page_size || settings.page_size
        raise AccessDenied, "INVALID_QUERY" unless size.is_a?(Integer) && size.between?(1, Presentation::IndexSettings::MAX_PAGE_SIZE)
        raise AccessDenied, "INVALID_QUERY" unless offset.nil? || offset.is_a?(Integer) && offset.between?(0, 99_999) && !recover_empty_page
        table = @resource.model_class.arel_table
        primary = @resource.model_class.primary_key
        sortable = @access.fields(:sort)
        field = if sort.present?
          sortable.find { |entry| entry.name.to_s == sort } || raise(AccessDenied, "INVALID_QUERY")
        elsif settings.default_sort
          # An ungranted default would reveal order on a hidden basis; skip it.
          direction = settings.default_direction
          sortable.find { |entry| entry.name == settings.default_sort }
        end
        if field
          # Empty values sort last in both directions on every database (RAA-028).
          relation = relation.reorder(table[field.column].public_send(direction).nulls_last)
          relation = relation.order(table[primary].asc) unless field.column == primary
        else
          relation = relation.reorder(table[primary].asc)
        end
        records = relation.offset(offset || (page.to_i - 1) * size).limit(size + 1).to_a
        number = page.to_i
        if recover_empty_page && records.empty? && number > 1
          count = relation.except(:order).limit(number * size).count
          number = [ 1, (count - 1).div(size) + 1 ].max
          records = relation.offset((number - 1) * size).limit(size + 1).to_a
        end
        total = relation.except(:order).limit(COUNT_LIMIT + 1).count if settings.count == :exact
        Page.new(records: records.first(size), number: number, has_next: records.size > size, scope: named&.name&.to_s,
          sort: field&.name&.to_s, direction: field ? direction : "asc", page_size: size,
          count: total && [ total, COUNT_LIMIT ].min, count_capped: !!total && total > COUNT_LIMIT)
      end

      # The bounded number of records the same search/scope/filters match,
      # capped like the index count. Same grants and validation as call.
      CountResult = Data.define(:count, :capped, :scope)
      def count(search: nil, scope: nil, filters: nil)
        @access.authorize!(:index)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters)
        total = relation.except(:order).limit(COUNT_LIMIT + 1).count
        CountResult.new([ total, COUNT_LIMIT ].min, total > COUNT_LIMIT, named&.name&.to_s)
      end

      # Coerces each wire value through the field's scalar contract. Values are
      # bound by Arel; no operator, column or SQL text comes from the request.
      def self.filter_value(field, operator, raw, time_zone:)
        raise AccessDenied, "INVALID_QUERY" unless field.filter_operators.include?(operator.to_sym) && FILTER_VALUE.call(raw)
        value = field.coerce(raw, time_zone: time_zone)
        raise AccessDenied, "INVALID_QUERY" if value.nil?
        value
      rescue ArgumentError
        raise AccessDenied, "INVALID_QUERY", cause: nil
      end

      private

      def filtered_relation(search:, scope:, filters:)
        # Leading and trailing spaces are never part of the term (RAA-021).
        search = search.strip if search.is_a?(String) && search.valid_encoding?
        unless search.nil? || search.is_a?(String) && search.valid_encoding? && (search.encoding == Encoding::UTF_8 || search.ascii_only?) && search.length <= 200 && !search.match?(/[\x00-\x1f\x7f]/)
          raise AccessDenied, "INVALID_QUERY"
        end
        unless scope.nil? || scope == NamedScope::NONE || scope.is_a?(String) && scope.valid_encoding? && scope.ascii_only? && scope.match?(NamedScope::NAME)
          raise AccessDenied, "INVALID_QUERY"
        end
        granted = @access.named_scopes
        unscoped = scope == NamedScope::NONE
        named = if unscoped then nil
        elsif scope.nil? then granted.find(&:default?)
        else granted.find { |definition| definition.name.to_s == scope }
        end
        raise AccessDenied, "INVALID_QUERY" if scope && !unscoped && !named
        relation = @access.relation
        relation = named.apply(relation) if named
        relation = apply_filters(relation, filters)
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
            @resource.model_class.arel_table[field.column].matches(pattern, "\\")
          end
          relation = relation.where(predicates.reduce(&:or))
        end
        [ relation, named ]
      end

      def apply_filters(relation, filters)
        return relation if filters.nil?
        unless filters.is_a?(Hash) && filters.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
            filters.values.all? { |conditions| conditions.is_a?(Hash) && conditions.any? && conditions.keys.all? { |key| AREL_PREDICATES.key?(key.to_s) } } &&
            filters.values.sum(&:size) <= MAX_FILTER_CONDITIONS
          raise AccessDenied, "INVALID_QUERY"
        end
        granted = @access.fields(:filter).index_by { |field| field.name.to_s }
        table = @resource.model_class.arel_table
        filters.reduce(relation) do |scoped, (name, conditions)|
          field = granted[name.to_s] or raise AccessDenied, "INVALID_QUERY"
          conditions.reduce(scoped) do |inner, (operator, raw)|
            value = self.class.filter_value(field, operator.to_s, raw, time_zone: @access.context.time_zone)
            inner.where(table[field.column].public_send(AREL_PREDICATES.fetch(operator.to_s), value))
          end
        end
      end
    end
  end
end
