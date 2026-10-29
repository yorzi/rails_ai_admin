class TenantsController < ApplicationController
  before_action :authenticate_staff_user!
  def update
    tenant = current_staff_user.tenants.find_by(id: params[:tenant_id])
    return head :not_found unless tenant
    session[:active_tenant_id] = tenant.id
    redirect_to "/operations", status: :see_other
  end
end
