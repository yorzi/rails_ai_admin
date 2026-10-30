# frozen_string_literal: true

Rails.application.routes.draw do
  root to: "custom_admin_pages#host_root"
  get "/host/customers/:id", to: "custom_admin_pages#show"
  mount RailsAiAdmin::Engine => "/backoffice", as: :rails_ai_admin
  # Isolated test fixture only, not a production authentication implementation.
  post "/test/sign_in/:id", to: "test_sessions#create"
end
