class AdminContext
  def resolve(controller)
    # TODO: authenticate through your host's public session/authentication API.
    # Return RailsAiAdmin::Context.new(actor:, tenant:, security_version:).
    # Increment security_version when session, role or tenant authority changes.
    nil
  end

  # Working example for an app made with `bin/rails generate authentication`
  # and a boolean `admin` column on users. Replace the method above with it
  # once you have reviewed it. Devise apps read controller.warden.user(:user).
  #
  # # One fixed tenant for an app without accounts. With an Account model,
  # # pass the user's account instead and scope the policy by it.
  # SingleTenant = Data.define(:id)
  # TENANT = SingleTenant.new(id: "app")
  #
  # def resolve(controller)
  #   session = Session.find_by(id: controller.request.cookie_jar.signed[:session_id])
  #   user = session&.user
  #   return unless user&.admin?
  #   # Any change to the user, including the admin flag, invalidates open forms.
  #   RailsAiAdmin::Context.new(actor: user, tenant: TENANT, security_version: user.updated_at.utc.iso8601(6))
  # end
end
