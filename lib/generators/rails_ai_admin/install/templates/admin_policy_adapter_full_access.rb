# Everyone AdminContext admits may use everything your resources declare, so
# the files in app/rails_ai_admin are the list of what the admin exposes.
# Override a decision here to narrow it; `super` keeps the rest.
class AdminPolicyAdapter < RailsAiAdmin::Authorization::FullAccessAdapter
  # Accounts: keep each admin inside their own tenant.
  #
  # def scope(context:, resource:, relation:)
  #   relation.where(account_id: context.tenant.id)
  # end

  # Roles: let only owners change records.
  #
  # def allowed?(context:, action:, resource:, record: nil)
  #   context.actor.owner? || %i[index show].include?(action)
  # end

  # Fields: keep one field out of reach on one resource.
  #
  # def fields(context:, resource:, action:, record: nil)
  #   resource.key == :users ? super - %i[notes] : super
  # end

  # The admin assistant stays off until you allow it. Allowing it sends the
  # record values a person asks about to your model provider.
  #
  # def assistant?(context:, resource:)
  #   true
  # end
end
