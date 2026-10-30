# frozen_string_literal: true

class CustomAdminPagesController < RailsAiAdmin::CustomController
  def host_root = render(plain: "Host root")

  def show
    access = admin_access(:customers)
    record = access.find!(params[:id])
    @values = access.project(record, view: :show)
    @engine_link = admin_routes.resource_path(resource: access.resource.key, id: record.id)
  end

  def prepare
    access = admin_access(:customers)
    record = access.find!(params[:id], action: :update)
    intent = admin_operation_runner.prepare(context: admin_context, resource: access.resource,
      operation: :update, target_id: record.id, expected_version: record.lock_version)
    render plain: intent.id
  end

  def save
    result = admin_operation_runner.execute(context: admin_context, intent_ref: params[:intent_ref],
      input: params.fetch(:record, ActionController::Parameters.new).to_unsafe_h, human_confirmed: true,
      binding: { resource_key: "customers", operation: :update, target_id: params[:id] })
    return admin_status(:not_found) if result.code == "NOT_FOUND"
    return admin_status(:conflict) unless result.success?
    render plain: "Saved through the shared runner"
  end

  def forbidden = admin_status(:forbidden)
  def explicit_error = admin_status(:error)
  def unavailable = raise(RailsAiAdmin::ConfigurationError, "private configuration SQL diagnostic")
  def unknown_denial = raise(RailsAiAdmin::AccessDenied, "private unknown error code")
  def broken = raise(StandardError, "Unhandled action failures remain visible to host exception handling")
end
