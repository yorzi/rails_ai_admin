# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    # One bounded observation and at most one input-bound member proposal.
    # Templates select a source; hosts supply their own resource, scope and operation.
    module Plan
      GALLERY = {
        "duplicate_detector" => "quality", "data_hygiene" => "quality", "order_monitor" => "list",
        "failed_job_investigator" => "failures", "daily_business_brief" => "report",
        "integrity_checker" => "quality", "audit_reviewer" => "audit"
      }.freeze
      Observation = Data.define(:count, :target, :version)
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
          unless %w[list quality].include?(source) && definition.custom? && definition.scope == :member &&
              definition.approval_mode == :separate_actor && !definition.merge? && plan.fetch("input", {}).is_a?(Hash)
            raise ConfigurationError, "Recipe proposals require a separately reviewed member operation"
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
          records = relation.limit(25).to_a
          record = records.first
          access.authorize!(:show, record) if record
          Observation.new(records.size, record&.id, record && RecordVersion.of(record))
        when "quality"
          reviews = Quality::Runner.new(access, assistant: true).call(plan.fetch("rule")).reviews
          ids = reviews.flat_map { |review| review.rows.map(&:id) }
          id = target_id ? ids.find { |candidate| candidate == target_id } : ids.first
          record = access.find!(id) if id
          Observation.new(reviews.size, id, record && RecordVersion.of(record))
        when "report"
          report = SavedQuery.visible(context).find_by(id: plan["report_id"], resource_key: resource.key)
          raise AccessDenied unless report
          result = Presentation::SavedQueries.evaluate(context, report, assistant: true)
          Observation.new(result.value || result.rows.size, nil, nil)
        when "audit", "failures"
          access.authorize_audit_log!
          events = AuditEvent.where(tenant_ref: context.tenant_ref, resource_key: resource.key, created_at: 24.hours.ago..)
          events = events.where.not(code: "OK") if plan["template"] == "failed_job_investigator"
          Observation.new(events.limit(1000).count, nil, nil)
        end
      end
    end
  end
end
