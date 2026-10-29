class AdminContext
  def resolve(controller)
    # Warden is the public Rack authentication boundary used by Devise helpers.
    authenticated = controller.request.env["warden"]&.authenticate(scope: :staff_user)
    actor = authenticated && StaffUser.find_by(id: authenticated.id)
    return unless actor
    selected = controller.session[:active_tenant_id]
    tenant = selected ? actor.tenants.find_by(id: selected) : actor.tenants.order(:id).first
    return unless tenant
    RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version.to_s)
  end
end
