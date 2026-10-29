Rails.application.routes.draw do
  devise_for :staff_users, only: :sessions
  root to: "portal#index"
  post "/tenant", to: "tenants#update"
  get "/favicon.ico", to: ->(_env) { [ 204, { "Content-Type" => "image/x-icon" }, [] ] }
  mount RailsAiAdmin::Engine => "/operations", as: :rails_ai_admin
  mount RailsToolViews::Engine => "/product_surfaces", as: :rails_tool_views
end
