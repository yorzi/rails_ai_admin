# frozen_string_literal: true

RailsAiAdmin::Engine.routes.prepend do
  get "custom/customers/:id", to: "/custom_admin_pages#show"
  get "custom/customers/:id/prepare", to: "/custom_admin_pages#prepare"
  post "custom/customers/:id/save", to: "/custom_admin_pages#save"
  get "custom/status/forbidden", to: "/custom_admin_pages#forbidden"
  get "custom/status/error", to: "/custom_admin_pages#explicit_error"
  get "custom/status/unavailable", to: "/custom_admin_pages#unavailable"
  get "custom/status/unknown", to: "/custom_admin_pages#unknown_denial"
  get "custom/status/broken", to: "/custom_admin_pages#broken"
end
