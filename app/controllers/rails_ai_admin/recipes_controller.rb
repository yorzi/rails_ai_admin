# frozen_string_literal: true

module RailsAiAdmin
  class RecipesController < ApplicationController
    def index
      raise AccessDenied unless Recipe.table_exists? && tasks_available?
      @recipes = Recipe.where(tenant_ref: @context.tenant_ref, owner_ref: @context.actor_ref).order(:name, :id).limit(100).filter_map do |recipe|
        Recipes.authorize!(@context, recipe)
        [ recipe, recipe.runs.order(created_at: :desc, id: :desc).limit(5) ]
      rescue AccessDenied
        nil
      end
    end

    def create
      raise AccessDenied unless Recipe.table_exists? && tasks_available?
      run = Recipes.trigger!(context: @context, slug: params[:slug], key: params[:occurrence])
      Recipes::ExecutionJob.perform_later(run.id) if run.status == "queued"
      redirect_to admin_recipes_path, status: :see_other
    end
  end
end
