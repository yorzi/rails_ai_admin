Rails.application.routes.draw do
  get "/favicon.ico", to: ->(_env) { [ 204, { "Content-Type" => "image/x-icon" }, [] ] }
  get "/login", to: "sessions#new"
  post "/login", to: "sessions#create"
  mount RailsAiAdmin::Engine => "/staff", as: :rails_ai_admin
end
