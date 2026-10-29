RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  # TODO: set a policy adapter; the default denies every action and field.
  # config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = []
end
