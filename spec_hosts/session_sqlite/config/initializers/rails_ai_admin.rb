RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = [ "CustomerAdmin", "CustomerDirectoryAdmin" ]
end
