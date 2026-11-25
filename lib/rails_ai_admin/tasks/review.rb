# frozen_string_literal: true

module RailsAiAdmin
  module Tasks
    # Read-only evidence shown before an approver confirms a proposal or an
    # operator undoes a committed run. Input values come from the immutable
    # intent (exactly what will execute); targets and changes are recomputed
    # now under the viewer's own grants, so nothing the viewer may not read is
    # shown and a target that changed since the proposal reports CONFLICT.
    module Review
      SAMPLE_LIMIT = 25
      Value = Data.define(:field, :value)
      Change = Data.define(:field, :before, :after)
      Target = Data.define(:id, :label, :changes, :code)
      Approval = Data.define(:values, :targets, :total_count) do
        def ready? = targets.any? && targets.all? { |target| target.code.nil? }
        def sampled? = total_count > targets.size
      end
      Undo = Data.define(:kind, :label, :changes)

      module_function

      def approval(context:, run:)
        resource = RailsAiAdmin.registry.fetch(run.resource_key)
        definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
        payload = run.input_payload.is_a?(Hash) ? run.input_payload : {}
        runner = Operations::Runner.new
        ActiveRecord::Base.while_preventing_writes do
          access = Authorization::Access.new(context, resource)
          pairs = if run.selection_id
            SelectionItem.where(selection_id: run.selection_id).order(:position).limit(SAMPLE_LIMIT)
              .pluck(:target_id, :expected_version)
          else
            [ [ run.target_id, run.expected_version ] ]
          end
          targets = pairs.map do |target_id, version|
            target(context, access, resource, definition, runner, run.operation, target_id, version, payload)
          end
          total = run.selection_id ? Array(run.manifest_payload).size : 1
          record = run.selection_id ? nil : visible_record(access, run.target_id)
          Approval.new(values: values(context, access, resource, definition, record, payload),
            targets: targets.freeze, total_count: total)
        end
      end

      def undo(context:, run:)
        resource = RailsAiAdmin.registry.fetch(run.resource_key)
        definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
        ActiveRecord::Base.while_preventing_writes do
          access = Authorization::Access.new(context, resource)
          if definition.custom?
            record = visible_record(access, run.record_id)
            next Undo.new(kind: :compensate, label: record && access.record_label(record), changes: [].freeze)
          end
          if run.operation == "destroy"
            record = access.discarded_relation.find_by(resource.model_class.primary_key => run.record_id)
            next Undo.new(kind: :restore, label: record && access.record_label(record), changes: [].freeze)
          end
          record = visible_record(access, run.record_id)
          next Undo.new(kind: :update, label: nil, changes: [].freeze) unless record
          current = access.project(record, view: :show)
          readable = access.fields(:read, record, view: :show).index_by { |field| field.name.to_s }
          changes = (run.undo_payload || {}).filter_map do |name, before|
            field = readable[name]
            next unless field && current.key?(name)
            Change.new(field: field, before: current[name], after: field.coerce_output(before, time_zone: context.time_zone))
          end
          Undo.new(kind: :update, label: access.record_label(record), changes: changes.freeze)
        end
      end

      def target(context, access, resource, definition, runner, operation, target_id, version, payload)
        record = visible_record(access, target_id)
        label = record ? access.record_label(record) : nil
        preview = runner.preview(context: context, resource: resource, operation: operation,
          target_id: target_id, expected_version: version, input: payload)
        return Target.new(id: target_id, label: label, changes: [].freeze, code: preview.code) if preview.is_a?(Operations::Result)
        fields = resource.fields.index_by { |field| field.name.to_s }
        changes = preview.changes.filter_map do |name, change|
          field = fields[name]
          Change.new(field: field, before: change["before"], after: change["after"]) if field
        end
        Target.new(id: target_id, label: label, changes: changes.freeze, code: nil)
      rescue AccessDenied => error
        Target.new(id: target_id, label: label, changes: [].freeze, code: error.code || "NOT_FOUND")
      end

      # Only the input fields this viewer may supply are shown: an approver who
      # lacks one could not confirm the intent anyway.
      def values(context, access, resource, definition, record, payload)
        granted = begin
          definition.fields(access, record)
        rescue AccessDenied
          []
        end
        coerced = InputSchema.new(granted, partial: true).coerce(payload.slice(*granted.map { |field| field.name.to_s }), time_zone: context.time_zone)
        source = coerced.valid? ? coerced.values : payload
        granted.filter_map do |field|
          name = field.name.to_s
          Value.new(field: field, value: source[name]) if payload.key?(name)
        end.freeze
      end

      def visible_record(access, id)
        return nil if id.blank?
        access.find!(id)
      rescue AccessDenied
        nil
      end
    end
  end
end
