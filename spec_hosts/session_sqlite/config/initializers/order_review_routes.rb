# Public Rails route hook: register once before the Engine draws its routes.
RailsAiAdmin::Engine.routes.prepend do
  get "workbench/orders/:id", to: "/order_reviews#show", as: :order_review
  post "workbench/orders/:id/preview", to: "/order_reviews#preview", as: :order_review_preview
  post "workbench/orders/:id/execute", to: "/order_reviews#execute", as: :order_review_execute
end
