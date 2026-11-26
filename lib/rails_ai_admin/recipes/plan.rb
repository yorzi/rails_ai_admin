# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    # One bounded observation and at most one input-bound proposal.
    # Templates select a source; hosts supply their own resource, scope and operation.
    module Plan
      GALLERY = {
        "duplicate_detector" => "quality", "data_hygiene" => "quality", "order_monitor" => "list",
        "failed_job_investigator" => "failures", "daily_business_brief" => "report",
        "integrity_checker" => "quality", "audit_reviewer" => "audit"
      }.freeze
      TARGET_LIMIT = 25
      Observation = Data.define(:count, :targets)
      module_function

      def validate!(recipe)
        plan = recipe.plan
        resource = RailsAiAdmin.registry.fetch(recipe.resource_key)
        unless plan.is_a?(Hash) && plan.to_json.bytesize <= 8192 && (plan.keys - %w[template scope rule report_id operation input consult_model]).empty?
          raise ConfigurationError, "Invalid recipe plan"
        end
        source = GALLERY.fetch(plan["template"]) { raise ConfigurationError, "Unknown recipe template" }
        raise ConfigurationError, "Quality recipes require a rule" if (source == "quality") != plan["rule"].present?
        RailsAiAdmin.quality_registry.fetch(resource, plan["rule"]) if source == "quality"
        raise ConfigurationError, "Briefs require a report" if (source == "report") != plan["report_id"].present?
        if plan.key?("scope") && (source != "list" || resource.scopes.none? { |entry| entry.name.to_s == plan["scope"] })
          raise ConfigurationError, "Unknown recipe scope"
        end
        raise ConfigurationError, "Expected a boolean" unless [ nil, false, true ].include?(plan["consult_model"])
        raise ConfigurationError, "A model decision requires an operation" if plan["consult_model"] && !plan["operation"]
        if plan["operation"]
          definition = RailsAiAdmin.operation_registry.fetch(resource, plan["operation"])
          unless %w[list quality].include?(source) && definition.custom? && %i[member collection].include?(definition.scope) &&
              definition.approval_mode == :separate_actor && !definition.merge? && plan.fetch("input", {}).is_a?(Hash)
            raise ConfigurationError, "Recipe proposals require a separately reviewed custom operation"
          end
        elsif plan.key?("input")
          raise ConfigurationError, "Recipe input requires an operation"
        end
      end

      def observe(context, recipe, target_id)
        plan = recipe.plan
        resource = RailsAiAdmin.registry.fetch(recipe.resource_key)
        access = Authorization::Access.new(context, resource)
        access.authorize_assistant!
        case GALLERY.fetch(plan.fetch("template"))
        when "list"
          relation = Queries::List.new(context, resource, assistant: true).relation(scope: plan["scope"])
          if target_id
            raise AccessDenied unless access.canonical_id?(target_id)
            relation = relation.where(resource.model_class.primary_key => target_id)
          end
          targets = relation.limit(TARGET_LIMIT).filter_map do |record|
            access.authorize!(:show, record)
            [ record.id.to_s, RecordVersion.of(record) ]
          rescue AccessDenied
            nil
          end
          Observation.new(targets.size, targets)
        when "quality"
          reviews = Quality::Runner.new(access, assistant: true).call(plan.fetch("rule")).reviews
          ids = reviews.flat_map { |review| review.rows.map(&:id) }
          ids = ids.select { |id| id == target_id } if target_id
          targets = ids.uniq.first(TARGET_LIMIT).map { |id| [ id, RecordVersion.of(access.find!(id)) ] }
          count = target_id ? reviews.count { |review| review.rows.any? { |row| row.id == target_id } } : reviews.size
          Observation.new(count, targets)
        when "report"
          report = SavedQuery.visible(context).find_by(id: plan["report_id"], resource_key: resource.key)
          raise AccessDenied unless report
          result = Presentation::SavedQueries.evaluate(context, report, assistant: true)
          Observation.new(result.query.query_ast["kind"] == "list" ? result.rows.size : result.value, [])
        when "failures"
          access.authorize_audit_log!
          runs = OperationRun.where(actor_ref: context.actor_ref, security_version: context.security_version,
            tenant_ref: context.tenant_ref, resource_key: resource.key)
          failed_work = WorkItem.where(status: %w[failed reconciliation_required], updated_at: 24.hours.ago..).select(:operation_run_id)
          candidates = runs.where(status: %w[failed partially_succeeded reconciliation_required], updated_at: 24.hours.ago..)
            .or(runs.where(id: failed_work)).order(updated_at: :desc, id: :desc).limit(100)
          count = candidates.count do |run|
            record = access.find!(run.target_id) if run.target_id
            access.authorize_receipt!(run.operation, record)
            true
          rescue AccessDenied
            false
          end
          Observation.new(count, [])
        when "audit"
          access.authorize_audit_log!
          events = AuditEvent.where(tenant_ref: context.tenant_ref, resource_key: resource.key, created_at: 24.hours.ago..)
          Observation.new(events.limit(1000).count, [])
        end
      end
    end
  end
end
