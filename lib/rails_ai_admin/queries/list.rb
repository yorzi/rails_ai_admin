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
      OPERATORS = Field::FILTER_OPERATORS.map(&:to_s).freeze

      def initialize(context, resource)
        @access = Authorization::Access.new(context, resource)
        @resource = resource
      end

      # scope: nil uses the declared default when it is currently granted;
      # NamedScope::NONE applies no named scope at all.
      # A named scope must be declared and granted; it is never discarded here.
      # filters: { "field" => { "eq" | "gte" | "lte" | "contains" | "blank" => "wire string", "in" => [ "wire string" ] } }, ANDed.
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
        relation, field, direction = sorted(relation, sort, direction)
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

      # The complete ordered relation the index shows across all its pages,
      # with the same grants and validation. Callers bound it themselves.
      def relation(search: nil, sort: nil, direction: "asc", scope: nil, filters: nil)
        @access.authorize!(:index)
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        relation, = filtered_relation(search: search, scope: scope, filters: filters)
        sorted(relation, sort, direction).first
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
      # contains keeps the stripped text itself; blank is "true" or "false";
      # in takes a list of distinct values, each coerced like eq.
      def self.filter_value(field, operator, raw, time_zone:)
        raise AccessDenied, "INVALID_QUERY" unless field.filter_operators.include?(operator.to_sym)
        if operator.to_s == "in"
          unless raw.is_a?(Array) && raw.size.between?(1, Field::MAX_IN_VALUES) && raw.all?(&FILTER_VALUE) && raw.uniq.size == raw.size
            raise AccessDenied, "INVALID_QUERY"
          end
          return raw.map { |item| coerce_filter(field, item, time_zone) }
        end
        raise AccessDenied, "INVALID_QUERY" unless FILTER_VALUE.call(raw)
        case operator.to_s
        when "blank"
          raise AccessDenied, "INVALID_QUERY" unless %w[true false].include?(raw)
          return raw == "true"
        when "contains"
          term = raw.strip
          raise AccessDenied, "INVALID_QUERY" if term.empty?
          return term
        end
        coerce_filter(field, raw, time_zone)
      end

      def self.coerce_filter(field, raw, time_zone)
        value = field.coerce(raw, time_zone: time_zone)
        raise AccessDenied, "INVALID_QUERY" if value.nil?
        value
      rescue ArgumentError
        raise AccessDenied, "INVALID_QUERY", cause: nil
      end
      private_class_method :coerce_filter

      # The Arel condition for one validated filter value.
      def self.filter_predicate(field, column, operator, value)
        case operator.to_s
        when "in" then column.in(value)
        when "contains" then column.matches("%#{ActiveRecord::Base.sanitize_sql_like(value)}%", "\\")
        when "blank"
          # Text stores "no value" as NULL or as an empty string.
          empty = Field::TEXT_TYPES.include?(field.scalar_type) ? column.eq(nil).or(column.eq("")) : column.eq(nil)
          value ? empty : empty.not
        else column.public_send(AREL_PREDICATES.fetch(operator.to_s), value)
        end
      end

      private

      def sorted(relation, sort, direction)
        settings = @resource.index
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
        if field&.scalar_type == :belongs_to
          # The target title from the target's own policy relation; a target
          # outside it sorts like an empty value.
          titles, title_column = reference_titles(field)
          relation = relation.joins(table.join(titles, Arel::Nodes::OuterJoin).on(titles[:raa_key].eq(table[field.column])).join_sources)
          relation = relation.reorder(titles[title_column].public_send(direction).nulls_last).order(table[primary].asc)
        elsif field
          # Empty values sort last in both directions on every database (RAA-028).
          relation = relation.reorder(table[field.column].public_send(direction).nulls_last)
          relation = relation.order(table[primary].asc) unless field.column == primary
        else
          relation = relation.reorder(table[primary].asc)
        end
        [ relation, field, direction ]
      end

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
            column = @resource.model_class.arel_table[field.column]
            if field.scalar_type == :belongs_to
              column.in(reference_matches(field, pattern))
            else
              column.matches(pattern, "\\")
            end
          end
          relation = relation.where(predicates.reduce(&:or))
        end
        [ relation, named ]
      end

      # A subquery of the target's policy relation: its key and title.
      def reference_titles(field)
        relation, model, title = reference_relation(field)
        table = model.arel_table
        [ relation.reselect(table[model.primary_key].as("raa_key"), table[title.column].as("raa_title")).distinct.arel.as("raa_reference_titles"), :raa_title ]
      end

      # Keys of target records in the target's policy relation whose title matches.
      def reference_matches(field, pattern)
        relation, model, title = reference_relation(field)
        table = model.arel_table
        relation.where(table[title.column].matches(pattern, "\\")).reselect(table[model.primary_key]).arel
      end

      def reference_relation(field)
        target = Fields::Association.target(field)
        access = Authorization::Access.new(@access.context, target)
        title = target.fields.find { |candidate| candidate.name == target.title }
        [ access.relation.unscope(:order, :limit, :offset), target.model_class, title ]
      end

      def apply_filters(relation, filters)
        return relation if filters.nil?
        unless filters.is_a?(Hash) && filters.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
            filters.values.all? { |conditions| conditions.is_a?(Hash) && conditions.any? && conditions.keys.all? { |key| OPERATORS.include?(key.to_s) } } &&
            filters.values.sum(&:size) <= MAX_FILTER_CONDITIONS
          raise AccessDenied, "INVALID_QUERY"
        end
        granted = @access.fields(:filter).index_by { |field| field.name.to_s }
        table = @resource.model_class.arel_table
        filters.reduce(relation) do |scoped, (name, conditions)|
          field = granted[name.to_s] or raise AccessDenied, "INVALID_QUERY"
          conditions.reduce(scoped) do |inner, (operator, raw)|
            value = self.class.filter_value(field, operator.to_s, raw, time_zone: @access.context.time_zone)
            inner.where(self.class.filter_predicate(field, table[field.column], operator, value))
          end
        end
      end
    end
  end
end
