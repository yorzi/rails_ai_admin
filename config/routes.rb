# frozen_string_literal: true

RailsAiAdmin::Engine.routes.draw do
  root to: "dashboard#index"
  get "jobs", to: "collection_jobs#index", as: :collection_jobs
  get "jobs/:job_ref", to: "collection_jobs#show", as: :collection_job
  post "jobs/:job_ref/cancel", to: "collection_jobs#cancel", as: :cancel_collection_job
  get ":resource/operations/:operation", to: "collection_operations#new", as: :collection_operation_form
  post ":resource/operations/:operation/preflight", to: "collection_operations#preflight", as: :collection_operation_preflight
  post ":resource/operations/:operation/execute", to: "collection_operations#execute", as: :collection_operation_execute
  post ":resource/selections", to: "selections#create", as: :capture_selection
  get "selections/:selection_ref", to: "selections#show", as: :selection
  get ":resource/:id/operations/:operation", to: "operations#new", as: :operation_form
  post ":resource/:id/operations/:operation/preflight", to: "operations#preflight", as: :operation_preflight
  post ":resource/:id/operations/:operation/execute", to: "operations#execute", as: :operation_execute
  get ":resource/forms/recover", to: "resources#recover_form", as: :recover_resource_form
  get ":resource/new", to: "resources#new", as: :new_resource
  get ":resource/:id/edit", to: "resources#edit", as: :edit_resource
  get ":resource/:id/confirm_destroy", to: "resources#confirm_destroy", as: :confirm_destroy_resource
  get ":resource", to: "resources#index", as: :resources
  post ":resource", to: "resources#create"
  get ":resource/:id", to: "resources#show", as: :resource
  patch ":resource/:id", to: "resources#update"
  delete ":resource/:id", to: "resources#destroy"
end
