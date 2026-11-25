# frozen_string_literal: true

module RailsAiAdmin
  class QualityRulesController < ApplicationController
    before_action :resolve_quality_resource

    def index
      @rules = RailsAiAdmin.quality_registry.for_access(@access)
      raise AccessDenied if @rules.empty?
    end

    def show
      @report = Quality::Runner.new(@access).call(params[:rule])
    end

    def merge
      @comparison = Quality::MergeReview.compare(@access, params[:rule], params[:group], params[:id])
    end

    private

    def resolve_quality_resource
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @access = Authorization::Access.new(@context, @resource)
    end
  end
end
