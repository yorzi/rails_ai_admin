# frozen_string_literal: true

module RailsAiAdmin
  class RecipeRun < ApplicationRecord
    self.table_name = "rails_ai_admin_recipe_runs"
    belongs_to :recipe, class_name: "RailsAiAdmin::Recipe", inverse_of: :runs
  end
end
