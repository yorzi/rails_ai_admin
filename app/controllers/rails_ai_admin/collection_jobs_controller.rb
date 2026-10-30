# frozen_string_literal: true

module RailsAiAdmin
  class CollectionJobsController < ApplicationController
    def index
      @jobs = Collections::Queries.new.recent(context: @context)
    end

    def show
      @job = Collections::Queries.new.fetch(context: @context, job_ref: params[:job_ref])
      @resource = RailsAiAdmin.registry.fetch(@job.resource_key)
    end

    def cancel
      result = Collections::Runner.new.cancel(context: @context, job_ref: params[:job_ref])
      return render plain: "The run is busy. Reload and try again.", status: :conflict if result.code == "CONFLICT"
      if result.code == "OUTCOME_UNKNOWN"
        return redirect_to collection_job_path(job_ref: result.job_ref), status: :see_other,
          notice: "Cancellation outcome is unknown. Refresh this existing run after recovery before taking further action."
      end
      raise AccessDenied unless result.job_ref
      redirect_to collection_job_path(job_ref: result.job_ref), status: :see_other,
        notice: "Cancellation processed. Already committed records and their follow-up work are retained."
    end
  end
end
