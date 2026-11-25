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
      run = Collections::Contract.owned(@context, params[:job_ref])
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

    def retry_failed
      run = Collections::Contract.owned(@context, params[:job_ref])
      @resource, @definition = Collections::Contract.definition(run)
      resolve_list_navigation
      outcome = Collections::Runner.new.retry_failed(context: @context, job_ref: params[:job_ref])
      if outcome.is_a?(Collections::Result)
        return redirect_to collection_job_path(job_ref: run.id, **navigation_params), status: :see_other,
          notice: admin_outcome(outcome.code)
      end
      @proposal = outcome.proposal
      @retry_omitted_count = outcome.omitted_count
      @wire_input = @proposal.intent.input_payload.to_json
      render "rails_ai_admin/collection_operations/confirmation"
    end
  end
end
