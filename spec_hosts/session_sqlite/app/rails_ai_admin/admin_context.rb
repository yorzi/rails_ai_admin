class AdminContext
  def resolve(controller)
    actor = User.find_by(id: controller.session[:user_id])
    return unless actor
    RailsAiAdmin::Context.new(actor: actor, tenant: actor.account, security_version: actor.security_version.to_s)
  end

  def resolve_job(actor_ref:, tenant_ref:, security_version:)
    return unless actor_ref.match?(/\Araa:actor:User:\d+\z/) && tenant_ref.match?(/\Araa:tenant:Account:\d+\z/)
    actor = User.find_by(id: actor_ref.split(":").last)
    tenant = Account.find_by(id: tenant_ref.split(":").last)
    return unless actor && tenant && actor.account_id == tenant.id
    RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version.to_s)
  end
end
