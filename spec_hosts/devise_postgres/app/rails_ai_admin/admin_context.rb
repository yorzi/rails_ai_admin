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

  def resolve_job(actor_ref:, tenant_ref:, security_version:)
    return unless actor_ref.match?(/\Araa:actor:StaffUser:\d+\z/) && tenant_ref.match?(/\Araa:tenant:Tenant:\d+\z/)
    actor = StaffUser.find_by(id: actor_ref.split(":").last)
    tenant = actor&.tenants&.find_by(id: tenant_ref.split(":").last)
    return unless actor && tenant
    RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version.to_s)
  end
end
