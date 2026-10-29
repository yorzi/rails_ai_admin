RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  # This generated adapter denies every scope, action and field.
  config.authorization_adapter = "AdminPolicyAdapter"
  # Review ExampleAdmin or generate a resource; nothing is registered by default.
  config.resources = []
end
