class ProductRuntime
  def self.scope(controller)
    user = controller.request.env["warden"]&.authenticate(scope: :staff_user)
    return unless user
    tenant_id = controller.session[:active_tenant_id] || user.tenants.order(:id).first&.id
    return unless user.tenants.exists?(id: tenant_id)
    RailsToolViews::Scope.new(actor: "product:StaffUser:#{user.id}", tenant: "product:Tenant:#{tenant_id}")
  end
end
