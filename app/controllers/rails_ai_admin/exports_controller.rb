# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  # Downloads the current list as CSV. POST keeps GET requests free of the
  # audit write and lets the CSRF token guard the download.
  class ExportsController < ApplicationController
    def create
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      access = Authorization::Access.new(@context, @resource)
      access.authorize_export!
      raw = params.to_unsafe_h.slice(*Navigation::ListState::KEYS).except("page")
      @list_navigation = Navigation::ListState.new(access, raw, strict: true)
      raise AccessDenied, "INVALID_QUERY" if @list_navigation.discarded?
      state = @list_navigation.state
      result = Presentation::CsvExport.new(@context, @resource).call(search: state["q"], sort: state["sort"],
        direction: state.fetch("direction", "asc"), scope: state["scope"], filters: state["filter"])
      if result.too_many
        redirect_to resources_path(resource: @resource.key, **state.symbolize_keys), status: :see_other,
          notice: t("rails_ai_admin.exports.too_many", limit: RailsAiAdmin.configuration.export_limit)
        return
      end
      AuditEvent.create!(actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref, resource_key: @resource.key.to_s,
        operation: "export", status: "succeeded", code: "OK", correlation_ref: SecureRandom.uuid, origin: "ui",
        changed_fields: result.fields, created_at: Time.current)
      filename = "#{@resource.key}-#{Time.current.in_time_zone(@context.time_zone).strftime('%Y%m%d-%H%M')}.csv"
      send_data result.body, filename: filename, type: "text/csv; charset=utf-8", disposition: "attachment"
    end
  end
end
