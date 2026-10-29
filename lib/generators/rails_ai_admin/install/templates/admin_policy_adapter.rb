class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  # Inherits the empty SQL scope, denied actions and empty field grants.
  # Implement all three contracts, or select the optional Pundit adapter.
  # Read the packaged README before granting access to any resource.
end
