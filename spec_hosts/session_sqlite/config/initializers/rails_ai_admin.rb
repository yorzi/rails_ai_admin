RailsAiAdmin.configure do |config|
  config.field_types = { trimmed_text: "TrimmedTextField" }
  config.authentication_path = "/login"
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.quality_rules = [ "MissingDeliveryDate" ]
  config.resources = [ "CustomerAdmin", "CustomerDirectoryAdmin", "OrderAdmin", "NoteAdmin" ]
end
