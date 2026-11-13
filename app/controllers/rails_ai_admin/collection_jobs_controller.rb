# frozen_string_literal: true

module RailsAiAdmin
  class CollectionJobsController < ApplicationController
    # The page exists only where its menu link does (RAA-030).
    def index
      raise AccessDenied unless collection_jobs_available?
      @jobs = Collections::Queries.new.recent(context: @context)
    end

    def show
      @job = Collections::Queries.new.fetch(context: @context, job_ref: params[:job_ref])
      @resource = RailsAiAdmin.registry.fetch(@job.resource_key)
      resolve_list_navigation
    end

    def cancel
      run = OperationRun.find_by(id: params[:job_ref], actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
      raise AccessDenied unless run
      @resource = RailsAiAdmin.registry.fetch(run.resource_key)
      resolve_list_navigation
      result = Collections::Runner.new.cancel(context: @context, job_ref: params[:job_ref])
      return render plain: t("rails_ai_admin.collection_jobs.busy"), status: :conflict if result.code == "CONFLICT"
      if result.code == "OUTCOME_UNKNOWN"
        return redirect_to collection_job_path(job_ref: result.job_ref, **navigation_params), status: :see_other,
          notice: t("rails_ai_admin.collection_jobs.cancel_unknown")
      end
      raise AccessDenied unless result.job_ref
      redirect_to collection_job_path(job_ref: result.job_ref, **navigation_params), status: :see_other,
        notice: t("rails_ai_admin.collection_jobs.cancelled")
    end
  end
end
