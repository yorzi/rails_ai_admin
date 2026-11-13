class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  # Inherits the empty SQL scope, denied actions and empty field grants.
  # Implement all three contracts, or select the optional Pundit adapter.
  # For trusted staff, inherit RailsAiAdmin::Authorization::FullAccessAdapter
  # instead. Rerunning the installer preserves this file.
  # Read the packaged README before granting access to any resource.

  # Working example to pair with the AdminContext example: every signed-in
  # admin may list, search and read users. Uncomment it after review; each
  # grant is a decision about your data. Editing also needs :update in
  # allowed?, a :write field list, an updated_at (or lock_version) column
  # and a resource without `readonly`.
  #
  # def scope(context:, resource:, relation:)
  #   resource.key == :users ? relation.all : relation.none
  # end
  #
  # def allowed?(context:, action:, resource:, record: nil)
  #   resource.key == :users && %i[index show].include?(action)
  # end
  #
  # def fields(context:, resource:, action:, record: nil)
  #   return [] unless resource.key == :users
  #   case action
  #   when :read then %i[id email_address created_at]
  #   when :search, :sort then %i[email_address]
  #   else []
  #   end
  # end
end
