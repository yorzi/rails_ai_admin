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
      MAX_OR_GROUPS = 5
      MAX_RELATION_FILTERS = 3
      RelationFilterSpec = Data.define(:name, :resource, :kind, :fields)
      FILTER_VALUE = ->(value) { value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) && value.length.between?(1, 200) && !value.match?(/[\x00-\x1f\x7f]/) }
      AREL_PREDICATES = { "eq" => :eq, "gte" => :gteq, "lte" => :lteq }.freeze
      OPERATORS = Field::FILTER_OPERATORS.map(&:to_s).freeze

      SEARCH_STRICTNESS = { exact: 0, prefix: 1, contains: 2 }.freeze

      def initialize(context, resource, assistant: false)
        @access = Authorization::Access.new(context, resource)
        @resource = resource
        @assistant = assistant == true
      end

      # scope: nil uses the declared default when it is currently granted;
      # NamedScope::NONE applies no named scope at all.
      # A named scope must be declared and granted; it is never discarded here.
      # filters: { "field" => { "eq" | "gte" | "lte" | "contains" | "blank" => "wire string", "in" => [ "wire string" ] } }, ANDed.
      # Every field needs a current :filter grant and a declared operator.
      def call(search: nil, sort: nil, direction: "asc", page: "1", recover_empty_page: false, scope: nil, filters: nil, any_filters: nil, relation_filters: nil, page_size: nil, offset: nil)
        @access.authorize!(:index)
        unless (page.is_a?(String) || page.is_a?(Integer)) && page.to_s.valid_encoding? && page.to_s.ascii_only? && page.to_s.match?(/\A[1-9]\d{0,3}\z/) && page.to_i <= 1000
          raise AccessDenied, "INVALID_QUERY"
        end
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters, any_filters: any_filters, relation_filters: relation_filters)
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
      def relation(search: nil, sort: nil, direction: "asc", scope: nil, filters: nil, any_filters: nil, relation_filters: nil)
        @access.authorize!(:index)
        raise AccessDenied, "INVALID_QUERY" unless %w[asc desc].include?(direction)
        relation, = filtered_relation(search: search, scope: scope, filters: filters, any_filters: any_filters, relation_filters: relation_filters)
        sorted(relation, sort, direction).first
      end

      # The bounded number of records the same search/scope/filters match,
      # capped like the index count. Same grants and validation as call.
      CountResult = Data.define(:count, :capped, :scope)
      def count(search: nil, scope: nil, filters: nil, any_filters: nil, relation_filters: nil)
        @access.authorize!(:index)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters, any_filters: any_filters, relation_filters: relation_filters)
        total = unique_records(relation).except(:order).limit(COUNT_LIMIT + 1).count
        CountResult.new([ total, COUNT_LIMIT ].min, total > COUNT_LIMIT, named&.name&.to_s)
      end

      # Single-hop declared relations the actor may filter through (belongs_to
      # fields granted for :filter, and has_many/has_one panels whose child
      # back-reference is readable). Each target requires :index (and assistant?
      # when assistant: true) plus at least one granted :filter field.
      def filterable_relations
        specs = []
        @access.fields(:filter).select { |field| field.scalar_type == :belongs_to }.each do |field|
          target = Fields::Association.target(field)
          fields = granted_target_filter_fields(target)
          next if fields.empty?
          specs << RelationFilterSpec.new(name: field.name.to_s, resource: target, kind: "belongs_to", fields: fields)
        end
        @resource.has_many_declarations.each do |definition|
          child, = resolve_child_relation(definition)
          next unless child
          fields = granted_target_filter_fields(child)
          next if fields.empty?
          specs << RelationFilterSpec.new(name: definition.name.to_s, resource: child, kind: definition.single ? "has_one" : "has_many", fields: fields)
        end
        specs.uniq(&:name)
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
      def aggregate(function:, field: nil, group_by: nil, period: nil, search: nil, scope: nil, filters: nil, any_filters: nil, relation_filters: nil)
        @access.authorize!(:index)
        raise AccessDenied, "INVALID_QUERY" unless AGGREGATE_FUNCTIONS.include?(function)
        raise AccessDenied, "INVALID_QUERY" unless period.nil? || PERIODS.include?(period) && !group_by.nil?
        measure = function == "count" ? nil : aggregate_field(field, function)
        raise AccessDenied, "INVALID_QUERY" if function == "count" && !field.nil?
        grouping = group_by.nil? ? nil : group_field(group_by, period: !period.nil?)
        relation, named = filtered_relation(search: search, scope: scope, filters: filters, any_filters: any_filters, relation_filters: relation_filters)
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
      def self.filter_predicate(field, column, operator, value, string_column: nil)
        case operator.to_s
        when "in" then column.in(value)
        when "contains" then column.matches("%#{ActiveRecord::Base.sanitize_sql_like(value)}%", "\\")
        when "blank"
          # Text stores "no value" as NULL or as an empty string; non-text PK columns cannot compare to "".
          allow_empty = field.scalar_type == :id ? (string_column == true) : Field::TEXT_TYPES.include?(field.scalar_type)
          empty = allow_empty ? column.eq(nil).or(column.eq("")) : column.eq(nil)
          value ? empty : empty.not
        else column.public_send(AREL_PREDICATES.fetch(operator.to_s), value)
        end
      end

      # Deduplicates policy relations that join other tables before counting or
      # paginating, avoiding DISTINCT on PostgreSQL JSON columns.
      def self.unique_records(relation)
        return relation unless relation.joins_values.any? || relation.left_outer_joins_values.any? || relation.eager_loading? || relation.distinct_value
        model = relation.klass
        key = model.primary_key
        ids = relation.reorder(nil).reselect(model.arel_table[key])
        records = model.unscoped.where(key => ids).readonly(relation.readonly_value).strict_loading(relation.strict_loading_value)
        preloads = relation.preload_values | relation.includes_values | relation.eager_load_values
        preloads.any? ? records.preload(*preloads) : records
      end

      private

      def aggregate_field(name, function)
        raise AccessDenied, "INVALID_QUERY" unless name.is_a?(String) && name.valid_encoding? && name.match?(Field::NAME)
        field = @access.fields(:read).find { |candidate| candidate.name.to_s == name && !candidate.virtual? }
        raise AccessDenied, "INVALID_QUERY" unless field&.aggregate_functions&.include?(function.to_sym)
        field
      end

      def group_field(name, period: false)
        raise AccessDenied, "INVALID_QUERY" unless name.is_a?(String) && name.valid_encoding? && name.match?(Field::NAME)
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
        sortable = @access.fields(:sort, assistant: @assistant)
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

      def unique_records(relation) = self.class.unique_records(relation)

      def filtered_relation(search:, scope:, filters:, any_filters: nil, relation_filters: nil)
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
        validate_filter_budget!(filters, any_filters, relation_filters)
        relation = @access.relation
        relation = named.apply(relation) if named
        relation = apply_filters(relation, filters)
        relation = apply_any_filters(relation, any_filters)
        relation = apply_relation_filters(relation, relation_filters)
        if search.present?
          fields = @access.fields(:search, assistant: @assistant)
          raise AccessDenied, "INVALID_QUERY" if fields.empty?
          predicates = fields.map do |field|
            term = ActiveRecord::Base.sanitize_sql_like(search)
            column = @resource.model_class.arel_table[field.column]
            if field.scalar_type == :belongs_to
              column.in(reference_matches(field, term))
            else
              column.matches(search_pattern(search_mode(field), term), "\\")
            end
          end
          relation = relation.where(predicates.reduce(&:or))
        end
        [ relation, named ]
      end

      def search_mode(field)
        mode = field.options[:searchable]
        mode == true ? :prefix : mode
      end

      def search_pattern(mode, term)
        case mode
        when :exact then term
        when :contains then "%#{term}%"
        else "#{term}%"
        end
      end

      # A subquery of the target's policy relation: its key and title.
      def reference_titles(field)
        relation, model, title = reference_relation(field)
        table = model.arel_table
        [ relation.reselect(table[model.primary_key].as("raa_key"), table[title.column].as("raa_title")).distinct.arel.as("raa_reference_titles"), :raa_title ]
      end

      # Keys of target records in the target's policy relation whose title matches.
      # Intersects the reference field's match mode with the target title's so a
      # referencing resource cannot weaken an :exact or :prefix target restriction.
      def reference_matches(field, term)
        relation, model, title = reference_relation(field)
        mode = [ search_mode(field), search_mode(title) ].min_by { |entry| SEARCH_STRICTNESS.fetch(entry, 1) }
        table = model.arel_table
        relation.where(table[title.column].matches(search_pattern(mode, term), "\\")).reselect(table[model.primary_key]).arel
      end

      def reference_relation(field)
        target = Fields::Association.target(field)
        access = Authorization::Access.new(@access.context, target)
        access.authorize_assistant! if @assistant
        title = target.fields.find { |candidate| candidate.name == target.title }
        [ access.relation.unscope(:order, :limit, :offset), target.model_class, title ]
      end

      def validate_filter_budget!(filters, any_filters, relation_filters)
        total = filter_condition_count(filters)
        if any_filters
          raise AccessDenied, "INVALID_QUERY" unless any_filters.is_a?(Array) && any_filters.size.between?(1, MAX_OR_GROUPS)
          any_filters.each do |group|
            raise AccessDenied, "INVALID_QUERY" unless group.is_a?(Hash) && group.any?
            total += filter_condition_count(group)
          end
        end
        if relation_filters
          raise AccessDenied, "INVALID_QUERY" unless relation_filters.is_a?(Hash) && relation_filters.size.between?(1, MAX_RELATION_FILTERS)
          relation_filters.each do |name, nested|
            raise AccessDenied, "INVALID_QUERY" unless (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(Field::NAME)
            raise AccessDenied, "INVALID_QUERY" unless nested.is_a?(Hash) && nested.any?
            total += filter_condition_count(nested)
          end
        end
        raise AccessDenied, "INVALID_QUERY" if total > MAX_FILTER_CONDITIONS
      end

      def filter_condition_count(filters)
        return 0 if filters.nil?
        unless filters.is_a?(Hash) && filters.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
            filters.values.all? { |conditions| conditions.is_a?(Hash) && conditions.any? && conditions.keys.all? { |key| OPERATORS.include?(key.to_s) } }
          raise AccessDenied, "INVALID_QUERY"
        end
        filters.values.sum(&:size)
      end

      def apply_filters(relation, filters)
        return relation if filters.nil? || filters.empty?
        filter_predicates_for(filters).reduce(relation) { |scoped, predicate| scoped.where(predicate) }
      end

      def apply_any_filters(relation, any_filters)
        return relation if any_filters.nil? || any_filters.empty?
        clauses = any_filters.map do |group|
          predicates = filter_predicates_for(group)
          raise AccessDenied, "INVALID_QUERY" if predicates.empty?
          predicates.reduce(&:and)
        end
        relation.where(clauses.reduce(&:or))
      end

      # Single-hop relation filters compiled as IN subqueries over the target
      # resource's own Policy::Scope + soft_delete + target :filter grants.
      # Using IN subqueries prevents row multiplication in counts/aggregates
      # and avoids table-name collisions on self-referential models.
      def apply_relation_filters(relation, relation_filters)
        return relation if relation_filters.nil? || relation_filters.empty?
        belongs_to_fields = @access.fields(:filter).select { |field| field.scalar_type == :belongs_to }.index_by { |field| field.name.to_s }
        panels = @resource.has_many_declarations.index_by { |definition| definition.name.to_s }
        parent_table = @resource.model_class.arel_table
        parent_pk = @resource.model_class.primary_key
        relation_filters.reduce(relation) do |scoped, (name, nested)|
          key = name.to_s
          if (field = belongs_to_fields[key])
            target = Fields::Association.target(field)
            target_relation = target_filtered_relation(target, nested)
            target_table = target.model_class.arel_table
            subquery = target_relation.reorder(nil).reselect(target_table[target.model_class.primary_key]).arel
            scoped.where(parent_table[field.column].in(subquery))
          elsif (definition = panels[key])
            child, via_field = resolve_child_relation(definition)
            raise AccessDenied, "INVALID_QUERY" unless child && via_field
            child_relation = target_filtered_relation(child, nested)
            fk_col = child.model_class.arel_table[via_field.column]
            subquery = child_relation.where(fk_col.not_eq(nil)).reorder(nil).reselect(fk_col).arel
            scoped.where(parent_table[parent_pk].in(subquery))
          else
            raise AccessDenied, "INVALID_QUERY"
          end
        end
      end

      def target_filtered_relation(target, nested)
        target_access = Authorization::Access.new(@access.context, target)
        target_access.authorize!(:index)
        target_access.authorize_assistant! if @assistant
        self.class.new(@access.context, target, assistant: @assistant).relation(filters: nested, scope: NamedScope::NONE)
      rescue AccessDenied
        raise AccessDenied, "INVALID_QUERY"
      end

      def granted_target_filter_fields(target)
        target_access = Authorization::Access.new(@access.context, target)
        target_access.authorize!(:index)
        target_access.authorize_assistant! if @assistant
        target_access.fields(:filter)
      rescue AccessDenied, ConfigurationError
        []
      end

      def resolve_child_relation(definition)
        child = RailsAiAdmin.registry.fetch(definition.resource)
        child_access = Authorization::Access.new(@access.context, child)
        child_access.authorize!(:index)
        child_access.authorize_assistant! if @assistant
        via_field = child.fields.find { |candidate| candidate.name == definition.via(@resource) }
        return nil unless via_field
        target = Fields::Association.validate!(child, via_field)
        return nil unless target.model_class == @resource.model_class
        return nil unless child_access.fields(:read, view: :index).include?(via_field)
        [ child, via_field ]
      rescue AccessDenied, ConfigurationError, KeyError
        nil
      end

      def filter_predicates_for(filters)
        granted = @access.fields(:filter).index_by { |field| field.name.to_s }
        model = @resource.model_class
        table = model.arel_table
        filters.flat_map do |name, conditions|
          field = granted[name.to_s] or raise AccessDenied, "INVALID_QUERY"
          col_type = model.type_for_attribute(field.column).type
          conditions.map do |operator, raw|
            value = self.class.filter_value(field, operator.to_s, raw, time_zone: @access.context.time_zone)
            value = cast_key_filter(field, operator.to_s, value, col_type)
            self.class.filter_predicate(field, table[field.column], operator, value, string_column: %i[string text].include?(col_type))
          end
        end
      end

      # Ensures raw Arel predicates on integer/UUID key columns receive valid
      # typed values so PostgreSQL never raises InvalidTextRepresentation.
      def cast_key_filter(field, operator, value, col_type)
        return value if operator == "blank" || !%i[belongs_to id].include?(field.scalar_type)
        cast_one = lambda do |item|
          case col_type
          when :integer
            raise AccessDenied, "INVALID_QUERY" unless item.is_a?(String) && item.match?(/\A[1-9][0-9]{0,18}\z/)
            number = Integer(item, 10)
            raise AccessDenied, "INVALID_QUERY" if number > 2**63 - 1
            number
          when :uuid
            raise AccessDenied, "INVALID_QUERY" unless item.is_a?(String) && item.match?(/\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z/)
            item
          else item
          end
        end
        operator == "in" ? value.map(&cast_one) : cast_one.call(value)
      end
    end
  end
end
