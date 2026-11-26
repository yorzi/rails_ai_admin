# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    class Origin < ActiveSupport::CurrentAttributes
      attribute :recipe
    end

    module_function

    # A trusted host supplies both contexts. The owner and principal need a
    # recipe grant on this resource; revisions invalidate queued work.
    def configure!(owner:, principal:, slug:, resource:, name:, instructions:, plan:, trigger: "manual",
      cron: nil, time_zone: "UTC", event: nil, overlap: "skip", daily_limit: 24, enabled: false)
      raise AccessDenied unless owner.is_a?(Context) && principal.is_a?(Context) && owner.tenant_ref == principal.tenant_ref
      recipe = Recipe.find_or_initialize_by(tenant_ref: owner.tenant_ref, slug: slug)
      Recipe.transaction do
        recipe.lock! if recipe.persisted?
        raise AccessDenied if recipe.persisted? && recipe.owner_ref != owner.actor_ref
        recipe.id ||= SecureRandom.uuid
        recipe.assign_attributes(owner_ref: owner.actor_ref, owner_epoch: owner.security_version, principal_ref: principal.actor_ref,
          principal_epoch: principal.security_version, resource_key: resource.to_s, name: name, instructions: instructions,
          plan: plan.deep_stringify_keys, trigger_kind: trigger, schedule_cron: cron, time_zone: time_zone, event_name: event,
          overlap_policy: overlap, max_runs_per_day: daily_limit, enabled: enabled, paused_at: nil, pause_reason: nil)
        authorize!(owner, recipe)
        authorize!(principal, recipe)
        recipe.save!
        recipe
      end
    end

    def authorize!(context, recipe)
      raise AccessDenied unless context.is_a?(Context) && recipe.tenant_ref == context.tenant_ref
      resource = RailsAiAdmin.registry.fetch(recipe.resource_key)
      Authorization::Access.new(context, resource).authorize_assistant!
      adapter = RailsAiAdmin.configuration.authorization_adapter.constantize.new
      raise AccessDenied unless adapter.respond_to?(:run_recipe?) && adapter.run_recipe?(context: context, resource: resource, slug: recipe.slug) == true
    end

    def principal!(recipe)
      adapter = RailsAiAdmin.configuration.context_adapter&.constantize&.new
      raise AccessDenied unless adapter.respond_to?(:resolve_job)
      identities = [ [ recipe.owner_ref, recipe.owner_epoch ], [ recipe.principal_ref, recipe.principal_epoch ] ]
      identities.uniq.to_h do |ref, epoch|
        current = begin
          adapter.resolve_job(actor_ref: ref, tenant_ref: recipe.tenant_ref, security_version: epoch)
        rescue StandardError
          raise AccessDenied, "AUTHORITY_REVOKED", cause: nil
        end
        raise AccessDenied unless current.is_a?(Context) && current.actor_ref == ref && current.security_version == epoch
        authorize!(current, recipe)
        [ [ ref, epoch ], current ]
      end.fetch(identities.last)
    end

    def check_approval!(intent)
      task = AdminTask.find_by(operation_run_id: intent.id, kind: "recipe_run")
      run = task && RecipeRun.find_by(id: task.summary_metadata["recipe_run_id"], task_id: task.id, tenant_ref: intent.tenant_ref)
      recipe = run&.recipe
      raise AccessDenied, "APPROVAL_INVALIDATED" unless recipe&.enabled? && recipe.version == run.recipe_version &&
        (recipe.trigger_kind != "event" || RailsAiAdmin.configuration.recipe_events.include?(recipe.event_name))
      current = principal!(recipe)
      raise AccessDenied unless current.actor_ref == intent.proposed_by_actor_ref && recipe.plan["operation"] == intent.operation
      observation = ActiveRecord::Base.while_preventing_writes { Plan.observe(current, recipe, intent.target_id) }
      raise AccessDenied, "APPROVAL_INVALIDATED" unless observation.target.to_s == intent.target_id && observation.version == intent.expected_version
      resource = RailsAiAdmin.registry.fetch(recipe.resource_key)
      preview = Operations::Runner.new.preview(context: current, resource: resource, operation: intent.operation,
        target_id: intent.target_id, expected_version: intent.expected_version, input: intent.input_payload)
      raise AccessDenied, "APPROVAL_INVALIDATED" if preview.is_a?(Operations::Result)
    end

    def trigger!(context:, slug:, key:)
      recipe = Recipe.find_by(tenant_ref: context.tenant_ref, owner_ref: context.actor_ref, slug: slug, trigger_kind: "manual")
      raise AccessDenied unless recipe && recipe.owner_epoch == context.security_version
      authorize!(context, recipe)
      recipe.with_lock { admit!(recipe, key: key) }
    end

    # Call from a committed host event with its stable message id. Only the
    # optional target id crosses into the recipe; business payloads stay local.
    def emit(event_name, tenant_ref:, dedup_key:, payload: {}, origin: nil)
      return [] if Origin.recipe || origin.to_s == "recipe" || !RailsAiAdmin.configuration.recipe_events.include?(event_name)
      target = payload.fetch(:record_id) { payload["record_id"] }
      raise AccessDenied, "INVALID_QUERY" unless target.nil? || (target.is_a?(String) || target.is_a?(Integer)) && target.to_s.bytesize.between?(1, 150)
      Recipe.where(tenant_ref: tenant_ref, trigger_kind: "event", event_name: event_name, enabled: true).find_each.filter_map do |recipe|
        recipe.with_lock do
          admit!(recipe, key: dedup_key, target: target&.to_s) if recipe.enabled? && recipe.event_name == event_name && recipe.trigger_kind == "event"
        end
      end
    end

    def scan(now: Time.current)
      Recipe.where(enabled: true, trigger_kind: "schedule", next_run_at: ..now).find_each do |recipe|
        recipe.with_lock do
          next unless recipe.enabled? && recipe.trigger_kind == "schedule" && recipe.next_run_at && recipe.next_run_at <= now
          local = recipe.next_run_at.in_time_zone(recipe.time_zone)
          # Both instants of a repeated wall-clock minute have the same key.
          admit!(recipe, key: "#{recipe.version}/#{local.strftime('%Y-%m-%dT%H:%M')}")
          recipe.update_columns(next_run_at: recipe.next_occurrence(after: now))
        end
      end
      RecipeRun.where(status: "running", started_at: ..(now - Execution::LEASE)).update_all(status: "failed",
        error_code: "WORKER_INTERRUPTED", completed_at: now, budget_slot: nil)
      RecipeRun.where(status: "queued").order(:created_at, :id).limit(100).pluck(:id).each { |id| ExecutionJob.perform_later(id) }
    end

    def admit!(recipe, key:, target: nil)
      raise AccessDenied unless recipe.enabled?
      raise AccessDenied, "INVALID_QUERY" unless key.is_a?(String) && key.valid_encoding? && key.bytesize.between?(1, 128) && !key.match?(Field::TEXT_CONTROLS)
      previous = recipe.runs.find_by(dedup_key: key)
      if previous
        raise AccessDenied, "IDEMPOTENCY_CONFLICT" unless previous.target_id == target && previous.trigger_kind == recipe.trigger_kind
        return previous
      end
      pending = recipe.runs.where(status: %w[queued running]).count
      status = if pending >= (recipe.overlap_policy == "queue_one" ? 2 : 1)
        "skipped_overlap"
      elsif recipe.runs.where(created_at: 24.hours.ago..).where.not(status: %w[budget_exceeded skipped_overlap cancelled]).count >= recipe.max_runs_per_day
        "budget_exceeded"
      else
        "queued"
      end
      recipe.runs.create!(recipe_version: recipe.version, tenant_ref: recipe.tenant_ref, principal_ref: recipe.principal_ref,
        trigger_kind: recipe.trigger_kind, dedup_key: key, target_id: target, status: status,
        definition: recipe.attributes.slice(*Recipe::DEFINITION), completed_at: (Time.current unless status == "queued"))
    end
    private_class_method :admit!
  end
end
