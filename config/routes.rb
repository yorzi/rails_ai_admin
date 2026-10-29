# frozen_string_literal: true

RailsAiAdmin::Engine.routes.draw do
  root to: "dashboard#index"
  get ":resource/:id/operations/:operation", to: "operations#new", as: :operation_form
  post ":resource/:id/operations/:operation/preflight", to: "operations#preflight", as: :operation_preflight
  post ":resource/:id/operations/:operation/execute", to: "operations#execute", as: :operation_execute
  get ":resource/new", to: "resources#new", as: :new_resource
  get ":resource/:id/edit", to: "resources#edit", as: :edit_resource
  get ":resource/:id/confirm_destroy", to: "resources#confirm_destroy", as: :confirm_destroy_resource
  get ":resource", to: "resources#index", as: :resources
  post ":resource", to: "resources#create"
  get ":resource/:id", to: "resources#show", as: :resource
  patch ":resource/:id", to: "resources#update"
  delete ":resource/:id", to: "resources#destroy"
end
