# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    class Execution
      LEASE = 10.minutes

      def self.call(id)
        run = RecipeRun.find_by(id: id)
        new(run).call if run
      end

      def initialize(run)
        @run = run
        @recipe = run.recipe
      end

      def call
        claimed = claim
        return unless claimed
        context = Recipes.principal!(@recipe)
        observation = observe(context)
        review = !@recipe.plan["consult_model"] || Budget.review?(@run, context, observation)
        @recipe.with_lock do
          @run.lock!
          return unless @run.status == "running"
          return finish("cancelled") unless current?
          context = Recipes.principal!(@recipe)
          fresh = observe(context)
          return finish("cancelled", "OBSERVATION_CHANGED") unless fresh == observation
          task = publish(context, fresh, review)
          @run.task_id = task.id
          finish("succeeded")
        end
      rescue AccessDenied
        @recipe.with_lock do
          @run.lock!
          return unless @run.status == "running"
          if current?
            @recipe.update_columns(enabled: false, next_run_at: nil, paused_at: Time.current, pause_reason: "AUTHORITY_REVOKED")
            finish("paused_revoked", "AUTHORITY_REVOKED")
          else
            finish("cancelled")
          end
        end
      rescue Budget::Exceeded
        fail_running("budget_exceeded", "RECIPE_BUDGET")
      rescue StandardError
        fail_running("failed", "RECIPE_FAILED") if claimed
        raise
      end

      private

      def observe(context)
        ActiveRecord::Base.while_preventing_writes { Plan.observe(context, @recipe, @run.target_id) }
      end

      def claim
        @recipe.with_lock do
          @run.lock!
          return false unless @run.status == "queued"
          unless current?
            finish("cancelled")
            return false
          end
          return false if @recipe.runs.where(status: "running").exists?
          first = @recipe.runs.where(status: "queued").order(:created_at, :id).pick(:id)
          return false unless first == @run.id
          @run.update!(status: "running", started_at: Time.current, budget_slot: (@recipe.tenant_ref if @recipe.plan["consult_model"]))
          true
        end
      rescue ActiveRecord::RecordNotUnique
        # Another recipe in this tenant owns the provider slot. The next scan retries.
        false
      end

      def current?
        @recipe.enabled? && @recipe.version == @run.recipe_version &&
          (@recipe.trigger_kind != "event" || RailsAiAdmin.configuration.recipe_events.include?(@recipe.event_name))
      end

      def publish(context, observation, review)
        metadata = { "recipe_id" => @recipe.id, "recipe_version" => @run.recipe_version, "recipe_run_id" => @run.id,
          "recipe_trigger" => @run.trigger_kind }
        if review && observation.targets.any? && @recipe.plan["operation"]
          resource = RailsAiAdmin.registry.fetch(@recipe.resource_key)
          Plan.validate!(@recipe)
          proposal = propose(context, resource, observation.targets)
          raise AccessDenied, proposal.code if proposal.is_a?(Operations::Result) || proposal.is_a?(Collections::Result)
          raise ConfigurationError, "Recipe inputs must be reviewable" unless proposal.intent.input_payload.is_a?(Hash)
          task = AdminTask.find_by!(operation_run_id: proposal.intent.id)
          task.update!(kind: "recipe_run", summary_metadata: task.summary_metadata.merge(metadata))
        else
          task = AdminTask.create!(id: SecureRandom.uuid, tenant_ref: context.tenant_ref, created_by_actor_ref: context.actor_ref,
            kind: "recipe_run", status: "succeeded", title: @recipe.name, resource_key: @recipe.resource_key,
            summary_metadata: metadata, completed_at: Time.current)
        end
        Tasks::Coordinator.append_event!(task, actor_ref: context.actor_ref, event_type: "recipe_run",
          message: "#{@recipe.slug} v#{@recipe.version} (#{@run.trigger_kind})")
        task
      end

      def propose(context, resource, targets)
        definition = RailsAiAdmin.operation_registry.fetch(resource, @recipe.plan.fetch("operation"))
        args = { context: context, resource: resource, operation: definition.key, input: @recipe.plan.fetch("input", {}), origin: :recipe }
        if definition.scope == :collection
          selection = Selections::Builder.new.capture(context: context, resource: resource, target_ids: targets.map(&:first))
          raise AccessDenied, "CONFLICT" unless selection.targets.to_h { |target| [ target.id, target.expected_version ] } == targets.to_h
          Collections::Runner.new.preflight(**args, selection_ref: selection.selection_ref)
        else
          id, version = targets.first
          Operations::Runner.new.preflight(**args, target_id: id, expected_version: version)
        end
      end

      def fail_running(status, code)
        @run.with_lock { finish(status, code) if @run.status == "running" }
      end

      def finish(status, code = nil)
        @run.update!(status: status, error_code: code, completed_at: Time.current, budget_slot: nil)
      end
    end
  end
end
