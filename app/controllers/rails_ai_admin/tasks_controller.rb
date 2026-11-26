# frozen_string_literal: true

module RailsAiAdmin
  class TasksController < ApplicationController
    def index
      raise AccessDenied unless tasks_available?
      @current_tab = Tasks::Coordinator::TABS.include?(params[:tab].to_s) ? params[:tab].to_s : "needs_approval"
      @resource_filter = params[:resource].presence
      @kind_filter = Tasks::Coordinator::KINDS.include?(params[:kind].to_s) ? params[:kind].to_s : nil
      @tasks = Tasks::Coordinator.list(context: @context, tab: @current_tab,
        resource_key: @resource_filter, kind: @kind_filter)
      refs = @tasks.flat_map { |task| [ task.created_by_actor_ref, task.assigned_to_actor_ref ] }.compact.uniq
      @actor_labels = actor_labels(refs)
    end

    def show
      load_task_workspace
    end

    def approve
      @task = Tasks::Coordinator.find_visible!(context: @context, id: params[:id])
      run = @task.operation_run_id && OperationRun.find_by(id: @task.operation_run_id, tenant_ref: @context.tenant_ref)
      raise AccessDenied unless run
      # The form carries the digest of the intent it showed, so a decision
      # always applies to the reviewed values.
      raise AccessDenied, "APPROVAL_INVALIDATED" unless params[:reviewed_digest].is_a?(String) &&
        ActiveSupport::SecurityUtils.secure_compare(params[:reviewed_digest], run.input_digest.to_s)

      if run.status == "proposed" && run.expires_at && run.expires_at <= Time.current
        Tasks::Coordinator.sync_from_run!(run, actor_ref: @context.actor_ref)
        load_task_workspace
        @failure_code = "APPROVAL_EXPIRED"
        return render :show, status: :conflict
      end

      result = if run.selection_id.present?
        Collections::Runner.new.admit(context: @context, intent_ref: run.id, input: run.input_payload || {},
          human_confirmed: true, approval_note: params[:approval_note])
      else
        Operations::Runner.new.execute(context: @context, intent_ref: run.id, input: run.input_payload || {},
          human_confirmed: true, origin: :ui, approval_note: params[:approval_note])
      end

      ok = result.respond_to?(:accepted?) ? result.accepted? : result.success?
      if ok
        redirect_to admin_task_path(id: @task.id), status: :see_other, notice: t("rails_ai_admin.tasks.approved")
      else
        load_task_workspace
        @failure_code = result.code
        render :show, status: :conflict
      end
    end

    def dismiss
      @task = Tasks::Coordinator.find_visible!(context: @context, id: params[:id])
      unless @task.created_by_actor_ref == @context.actor_ref || Tasks::Coordinator.can_approve?(@context, @task)
        raise AccessDenied
      end
      begin
        Tasks::Coordinator.dismiss!(context: @context, task: @task)
      rescue AccessDenied => error
        raise unless error.code == "CONFLICT"
        load_task_workspace
        @failure_code = "CONFLICT"
        return render :show, status: :conflict
      end
      redirect_to admin_task_path(id: @task.id), status: :see_other, notice: t("rails_ai_admin.tasks.dismissed")
    end

    def undo
      @task = Tasks::Coordinator.find_visible!(context: @context, id: params[:id])
      raise AccessDenied unless @task.operation_run_id
      runner = Operations::Runner.new
      proposal = runner.preflight_undo(context: @context, run_id: @task.operation_run_id, origin: :ui)
      if proposal.is_a?(Operations::Result)
        load_task_workspace
        @failure_code = proposal.code
        return render :show, status: :conflict
      end
      result = runner.execute_undo(context: @context, intent_ref: proposal.intent.id, human_confirmed: true, origin: :ui)
      if result.success?
        redirect_to admin_task_path(id: @task.id), status: :see_other, notice: t("rails_ai_admin.tasks.undone")
      else
        load_task_workspace
        @failure_code = result.code
        render :show, status: :conflict
      end
    end

    private

    def load_task_workspace
      @task = Tasks::Coordinator.find_visible!(context: @context, id: params[:id])
      @effective_status = Tasks::Coordinator.effective_status(@task)
      @polling = %w[executing verifying].include?(@effective_status)
      @run = @task.operation_run_id ? OperationRun.find_by(id: @task.operation_run_id, tenant_ref: @context.tenant_ref) : nil
      @resource = @task.resource_key.present? ? RailsAiAdmin.registry.fetch(@task.resource_key) : nil
      @can_approve = Tasks::Coordinator.can_approve?(@context, @task)
      @can_dismiss = @effective_status == "awaiting_approval" && (@task.created_by_actor_ref == @context.actor_ref || @can_approve)
      @can_undo = Tasks::Coordinator.can_undo?(@context, @task)
      @approval_review = Tasks::Review.approval(context: @context, run: @run) if @can_approve
      if @approval_review&.ready? && RailsAiAdmin.operation_registry.fetch(@resource, @run.operation).merge?
        @merge_comparison = Quality::MergeReview.confirmed_comparison(Authorization::Access.new(@context, @resource),
          @run.operation, @run.target_id, @run.input_payload.fetch("merge_review"))
      end
      @undo_review = Tasks::Review.undo(context: @context, run: @run) if @can_undo
      if @task.kind == "recipe_run" && !@run
        recipe_run = RecipeRun.find_by(task_id: @task.id, id: @task.summary_metadata["recipe_run_id"])
        recipe = recipe_run&.recipe
        if recipe&.enabled? && recipe.version == recipe_run.recipe_version
          begin
            Recipes.authorize!(@context, recipe)
            @recipe_observation = ActiveRecord::Base.while_preventing_writes { Recipes::Plan.observe(@context, recipe, recipe_run.target_id) }
          rescue AccessDenied
            @recipe_observation = nil
          end
        end
      end
      @events = @task.events.to_a
      refs = ([ @task.created_by_actor_ref, @task.assigned_to_actor_ref, @run&.approved_by_ref ] + @events.map(&:actor_ref)).compact.uniq
      @actor_labels = actor_labels(refs)
    end
  end
end
