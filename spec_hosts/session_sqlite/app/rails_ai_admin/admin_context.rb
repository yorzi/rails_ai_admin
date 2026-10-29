class AdminContext
  def resolve(controller)
    actor = User.find_by(id: controller.session[:user_id])
    return unless actor
    RailsAiAdmin::Context.new(actor: actor, tenant: actor.account, security_version: actor.security_version.to_s)
  end
end
