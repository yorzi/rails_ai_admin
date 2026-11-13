# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Declared overview widgets: counts over a granted list tab and daily
    # trends over a readable date field. Every number comes from the
    # resource's policy relation; nothing is cached across requests.
    module Dashboard
      MAX_WIDGETS = 8
      MAX_DAYS = 90
      # A trend reads at most this many timestamps.
      TREND_LIMIT = 50_000
      Metric = Data.define(:name, :scope, :label)
      Trend = Data.define(:name, :field, :days, :label)
      MetricValue = Data.define(:label, :count, :capped, :scope)
      TrendValue = Data.define(:label, :days, :capped) do
        def max = [ days.map(&:last).max.to_i, 1 ].max
        def total = days.sum(&:last)
      end
      Section = Data.define(:resource, :metrics, :trends)

      # Collects a resource's dashboard declarations.
      class Builder
        attr_reader :widgets

        def initialize = @widgets = []

        def metric(name, scope: nil, label: nil)
          add(Metric.new(stable(name), scope && stable(scope), text(label)))
        end

        def trend(field, days: 30, label: nil)
          raise ConfigurationError, "trend days must be 7..#{MAX_DAYS}" unless days.is_a?(Integer) && days.between?(7, MAX_DAYS)
          add(Trend.new(stable(field), stable(field), days, text(label)))
        end

        private

        def add(widget)
          raise ConfigurationError, "A dashboard declares at most #{MAX_WIDGETS} widgets" if @widgets.size >= MAX_WIDGETS
          raise ConfigurationError, "Duplicate dashboard widget #{widget.name}" if @widgets.any? { |entry| entry.class == widget.class && entry.name == widget.name }
          @widgets << widget.freeze
        end

        def stable(name)
          raise ConfigurationError, "Dashboard names must be stable identifiers" unless (name.is_a?(Symbol) || name.is_a?(String)) && name.to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
          name.to_sym
        end

        def text(label)
          return if label.nil?
          raise ConfigurationError, "Dashboard labels must be short plain text" unless label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 80)
          label.dup.freeze
        end
      end

      class << self
        def validate!(resource)
          resource.dashboard.each do |widget|
            case widget
            when Metric
              if widget.scope && resource.scopes.none? { |definition| definition.name == widget.scope }
                raise ConfigurationError, "dashboard metric #{widget.name} names undeclared list tab #{widget.scope}"
              end
            when Trend
              field = resource.fields.find { |candidate| candidate.name == widget.field }
              unless field && %i[date datetime].include?(field.scalar_type) && !field.virtual? && !field.plugin?
                raise ConfigurationError, "dashboard trend #{widget.field} must name a declared date or datetime field"
              end
            end
          end
        end

        # One section per menu resource with widgets the actor may see now.
        def build(context, resources)
          resources.filter_map do |resource|
            next if resource.dashboard.empty?
            access = Authorization::Access.new(context, resource)
            access.authorize!(:index)
            metrics = resource.dashboard.grep(Metric).filter_map { |widget| metric(access, widget) }
            trends = resource.dashboard.grep(Trend).filter_map { |widget| trend(access, widget) }
            Section.new(resource, metrics.freeze, trends.freeze) if metrics.any? || trends.any?
          rescue AccessDenied
            nil
          end
        end

        private

        def metric(access, widget)
          relation = access.relation
          if widget.scope
            named = access.named_scopes.find { |definition| definition.name == widget.scope }
            return unless named
            relation = named.apply(relation)
          end
          total = relation.except(:order).limit(List::COUNT_LIMIT + 1).count
          label = widget.label || (named ? "#{access.resource.label}: #{named.label}" : access.resource.label)
          MetricValue.new(label, [ total, List::COUNT_LIMIT ].min, total > List::COUNT_LIMIT, named&.name&.to_s)
        end

        # Counts per day in the context's time zone for the last days.
        def trend(access, widget)
          field = access.fields(:read).find { |candidate| candidate.name == widget.field }
          return unless field
          zone = ActiveSupport::TimeZone[access.context.time_zone]
          today = zone.today
          first = today - (widget.days - 1)
          start = field.scalar_type == :date ? first : zone.local(first.year, first.month, first.day)
          column = access.resource.model_class.arel_table[field.column]
          values = access.relation.where(column.gteq(start)).reorder(nil).limit(TREND_LIMIT + 1).pluck(field.column)
          counts = Hash.new(0)
          values.first(TREND_LIMIT).compact.each { |value| counts[value.respond_to?(:in_time_zone) && !value.is_a?(Date) ? value.in_time_zone(zone).to_date : value.to_date] += 1 }
          days = (first..today).map { |day| [ day, counts[day] ] }
          TrendValue.new(widget.label || "#{access.resource.label} by #{field.label.downcase_first}", days.freeze, values.size > TREND_LIMIT)
        end
      end

      List = Queries::List
    end
  end
end
