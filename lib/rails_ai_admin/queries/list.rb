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
        total = unique_records(relation).except(:order).limit(COUNT_LIMIT + 1).count
        CountResult.new([ total, COUNT_LIMIT ].min, total > COUNT_LIMIT, named&.name&.to_s)
      end

      # Counts and aggregates over the same search, scope and filters as the
      # list. field must be declared aggregatable and readable; group_by must
      # be a boolean, choice or belongs_to field the actor may filter by, since
      # filtering by each value would show the same counts. Aggregates run over
      # the primary keys of the policy relation, so a join in a policy scope
      # cannot count a record twice. Values are type cast but not formatted.
      # With period, group_by is a date or datetime field the actor may filter
      # by, and groups are calendar periods in the actor's time zone.
      AGGREGATE_FUNCTIONS = %w[count sum average minimum maximum].freeze
      PERIODS = %w[day week month year].freeze
      MAX_GROUPS = 25
      Aggregate = Data.define(:function, :field, :group_by, :count, :value, :groups, :groups_truncated, :scope, :period)
      Group = Data.define(:key, :count, :value)
      def aggregate(function:, field: nil, group_by: nil, period: nil, search: nil, scope: nil, filters: nil)
        @access.authorize!(:index)
        raise AccessDenied, "INVALID_QUERY" unless AGGREGATE_FUNCTIONS.include?(function)
        raise AccessDenied, "INVALID_QUERY" unless period.nil? || PERIODS.include?(period) && !group_by.nil?
        measure = function == "count" ? nil : aggregate_field(field, function)
        raise AccessDenied, "INVALID_QUERY" if function == "count" && !field.nil?
        grouping = group_by.nil? ? nil : group_field(group_by, period: !period.nil?)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters)
        model = @resource.model_class
        primary = model.primary_key
        base = model.unscoped.where(primary => relation.except(:order).reselect(model.arel_table[primary]))
        table = model.arel_table
        expressions = [ Arel.star.count ]
        expressions << table[measure.column].public_send(AREL_AGGREGATES.fetch(function)) if measure
        count, raw = base.pick(*expressions)
        groups, truncated = [], false
        if grouping && period
          groups, truncated = period_groups(base, table[grouping.column], grouping, period, expressions, measure, function)
        elsif grouping
          column = table[grouping.column]
          rows = base.group(column).order(Arel.star.count.desc, column.asc.nulls_last).limit(MAX_GROUPS + 1).pluck(column, *expressions)
          truncated = rows.size > MAX_GROUPS
          groups = rows.first(MAX_GROUPS).map do |key, group_count, group_raw|
            Group.new(cast(grouping, key), group_count.to_i, measure ? aggregate_value(measure, function, group_raw) : nil)
          end
        end
        Aggregate.new(function, measure, grouping, count.to_i, measure ? aggregate_value(measure, function, raw) : nil, groups, truncated,
          named&.name&.to_s, period)
      end

      AREL_AGGREGATES = { "sum" => :sum, "average" => :average, "minimum" => :minimum, "maximum" => :maximum }.freeze

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

      def aggregate_field(name, function)
        raise AccessDenied, "INVALID_QUERY" unless name.is_a?(String) && name.match?(Field::NAME)
        field = @access.fields(:read).find { |candidate| candidate.name.to_s == name && !candidate.virtual? }
        raise AccessDenied, "INVALID_QUERY" unless field&.aggregate_functions&.include?(function.to_sym)
        field
      end

      def group_field(name, period: false)
        raise AccessDenied, "INVALID_QUERY" unless name.is_a?(String) && name.match?(Field::NAME)
        field = @access.fields(:filter).find { |candidate| candidate.name.to_s == name }
        raise AccessDenied, "INVALID_QUERY" unless field && (period ? Field::PERIOD_TYPES : Field::GROUP_TYPES).include?(field.scalar_type)
        field
      end

      # Calendar periods, oldest first, ending with the latest dated record's
      # period; periods without records count zero. Each record falls in one
      # period through a CASE over bound boundaries, so SQLite and PostgreSQL
      # agree and datetimes split at midnight in the actor's time zone. Past
      # MAX_GROUPS periods only the latest are returned. Records without a
      # date form a final group whose key is nil, beyond that limit.
      def period_groups(base, column, field, period, expressions, measure, function)
        zone = ActiveSupport::TimeZone[@access.context.time_zone]
        first, last = base.pick(column.minimum, column.maximum).map { |raw| cast(field, raw) }
        starts = []
        if last
          day = ->(value) { field.scalar_type == :datetime ? value.in_time_zone(zone).to_date : value }
          oldest = period_start(day.call(first), period)
          start = period_start(day.call(last), period)
          while start >= oldest && starts.size <= MAX_GROUPS
            starts.unshift(start)
            start = period_advance(start, period, -1)
          end
        end
        truncated = starts.size > MAX_GROUPS
        starts = starts.last(MAX_GROUPS)
        edge = ->(date) { field.scalar_type == :datetime ? zone.local(date.year, date.month, date.day) : date }
        bucket = Arel::Nodes::Case.new.when(column.eq(nil)).then(Arel::Nodes.build_quoted(-1))
        starts.each_with_index do |start, index|
          range = column.gteq(edge.call(start)).and(column.lt(edge.call(period_advance(start, period, 1))))
          bucket = bucket.when(range).then(Arel::Nodes.build_quoted(index))
        end
        # Records before the returned periods fall to -2 and are left out.
        bucket = bucket.else(Arel::Nodes.build_quoted(-2))
        rows = base.group(bucket).pluck(bucket, *expressions).to_h { |index, *values| [ index.to_i, values ] }
        groups = starts.each_with_index.map do |start, index|
          group_count, group_raw = rows.fetch(index, [ 0, nil ])
          Group.new(start, group_count.to_i, measure ? aggregate_value(measure, function, group_raw) : nil)
        end
        if (undated = rows[-1])
          groups << Group.new(nil, undated[0].to_i, measure ? aggregate_value(measure, function, undated[1]) : nil)
        end
        [ groups, truncated ]
      end

      def period_start(date, period)
        case period
        when "day" then date
        when "week" then date.beginning_of_week(:monday)
        when "month" then date.beginning_of_month
        else date.beginning_of_year
        end
      end

      def period_advance(date, period, steps)
        date.advance({ "day" => :days, "week" => :weeks, "month" => :months, "year" => :years }.fetch(period) => steps)
      end

      # Database results arrive as the adapter returns them (SQLite sums
      # decimals as floats); each is cast through the column's type.
      def cast(field, raw)
        return nil if raw.nil?
        @resource.model_class.type_for_attribute(field.column).deserialize(raw)
      end

      def aggregate_value(field, function, raw)
        return nil if raw.nil?
        case function
        when "average" then BigDecimal(raw.to_s)
        when "sum" then field.scalar_type == :integer ? BigDecimal(raw.to_s).to_i : BigDecimal(raw.to_s)
        else cast(field, raw)
        end
      end

      def sorted(relation, sort, direction)
        relation = unique_records(relation)
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

      # A policy join can return several rows for one record. Paginate and
      # count the authorized keys before sorting or projecting model columns.
      # Using IDs also avoids DISTINCT on PostgreSQL JSON columns.
      def unique_records(relation)
        return relation unless relation.joins_values.any? || relation.left_outer_joins_values.any? || relation.eager_loading? || relation.distinct_value
        model = relation.klass
        key = model.primary_key
        ids = relation.reorder(nil).reselect(model.arel_table[key])
        records = model.unscoped.where(key => ids).readonly(relation.readonly_value).strict_loading(relation.strict_loading_value)
        preloads = relation.preload_values | relation.includes_values | relation.eager_load_values
        preloads.any? ? records.preload(*preloads) : records
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
