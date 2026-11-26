# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    module SavedQueries
      COMMON = %w[scope search filters any_filters relation_filters].freeze
      OPTIONS = { "metric" => %w[function field group_by period period_field], "list" => %w[sort direction] }.freeze
      Report = Data.define(:query, :resource, :value, :rows, :truncated, :evaluated_at)

      module_function

      def save!(context:, resource:, name:, ast:, shared:, pinned:)
        raise AccessDenied, "INVALID_QUERY" unless name.is_a?(String) && name.strip.length.between?(1, 80) && !name.match?(Field::TEXT_CONTROLS)
        raise AccessDenied if shared && !shareable?(context, resource)
        report = SavedQuery.new(id: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          resource_key: resource.key, name: name.strip, shared: shared, pinned: pinned, query_ast: ast)
        evaluate(context, report)
        report.save!
        report
      end

      def shareable?(context, resource)
        adapter = RailsAiAdmin.configuration.authorization_adapter.constantize.new
        adapter.respond_to?(:share_reports?) && adapter.share_reports?(context: context, resource: resource) == true
      end

      def evaluate(context, report)
        raise AccessDenied unless report.owned_by?(context) || report.shared? && report.tenant_ref == context.tenant_ref
        resource = RailsAiAdmin.registry.fetch(report.resource_key)
        access = Authorization::Access.new(context, resource)
        access.authorize!(:index)
        ast = report.query_ast
        raise AccessDenied, "INVALID_QUERY" unless report.ast_version == 1 && ast.is_a?(Hash) && ast.to_json.bytesize <= 8192
        kind = ast["kind"]
        keys = OPTIONS[kind]
        raise AccessDenied, "INVALID_QUERY" unless keys && (ast.keys - COMMON - keys - [ "kind" ]).empty?
        args = ast.except("kind").symbolize_keys
        list = Queries::List.new(context, resource)
        if kind == "list"
          page = list.call(**args)
          rows = page.records.filter_map do |record|
            access.authorize!(:show, record)
            [ access.record_label(record, view: :index), record.id.to_s ]
          rescue AccessDenied
            nil
          end
          Report.new(report, resource, nil, rows, page.has_next, Time.current)
        else
          aggregate = list.aggregate(**args.reverse_merge(function: "count"))
          resolver = Fields::Association.new(context, resource)
          dimension = aggregate.group_by
          resolver.prime(dimension, aggregate.groups.map(&:key)) if dimension&.scalar_type == :belongs_to
          rows = aggregate.groups.map do |group|
            label = if dimension.scalar_type == :belongs_to
              resolver.reference(dimension, group.key)&.label
            else
              group.key.to_s
            end
            label = [ group.period_start, label ].compact.join(" · ") if aggregate.period_field
            [ label.presence || "—", aggregate.field ? group.value : group.count ]
          end
          Report.new(report, resource, aggregate.field ? aggregate.value : aggregate.count, rows, aggregate.groups_truncated, Time.current)
        end
      end

      def renderable(context, relation)
        relation.order(created_at: :desc, id: :desc).limit(25).filter_map do |report|
          evaluate(context, report)
        rescue AccessDenied
          nil
        end
      end
    end
  end
end
