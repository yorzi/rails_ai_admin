# frozen_string_literal: true

module RailsAiAdmin
  # Admin-owned rails_tool_views endpoints (plan §6.3.1 shared mode). They use
  # the public present/restore/dispatch/render API with an explicit admin Scope
  # and never the host's global resolver, parent controller or agent adapter.
  # rails_tool_views is referenced only inside actions, so conventional hosts
  # can eager-load this file without loading the integration.
  class SurfacesController < ApplicationController
    ACT_FIELDS = %w[action_name base_revision idempotency_key source_component arguments].freeze
    FORM_FURNITURE = %w[authenticity_token commit button].freeze

    before_action :require_surfaces
    around_action :bind_admin_context

    # Native confirmation page -> persistent review Surface for the same intent.
    def create
      resource = RailsAiAdmin.registry.fetch(params[:resource])
      definition = RailsAiAdmin.operation_registry.fetch(resource, params[:operation])
      access = Authorization::Access.new(@context, resource)
      record = access.find!(params[:id], action: definition.key)
      surface = tool_views.present(context: @context, resource: resource, definition: definition, record: record,
        intent_ref: params[:intent_ref], input: confirmed_input)
      redirect_to admin_surface_path(surface_id: surface.id), status: :see_other
    rescue AccessDenied => error
      # An authorized actor with an expired, invalidated or input-mismatched
      # intent gets the native conflict status, not anti-enumeration 404.
      raise unless %w[APPROVAL_EXPIRED APPROVAL_INVALIDATED].include?(error.code)
      admin_status(:conflict)
    rescue ::RailsToolViews::Error => error
      # The same intent was already presented with different input.
      error.code == "IDEMPOTENCY_CONFLICT" ? admin_status(:conflict) : reject(error)
    end

    def show
      @surface = ::RailsToolViews.restore(params[:surface_id], scope: admin_scope)
      @surface_scope = admin_scope
    rescue ::RailsToolViews::Error => error
      reject(error)
    end

    def act
      input = request.request_parameters.except(*FORM_FURNITURE)
      raise AccessDenied, "INVALID_QUERY" unless (input.keys - ACT_FIELDS).empty?
      revision = input["base_revision"]
      raise AccessDenied, "INVALID_QUERY" unless revision.is_a?(String) && revision.match?(/\A[1-9][0-9]{0,9}\z/)
      arguments = input.fetch("arguments", {})
      raise AccessDenied, "INVALID_QUERY" unless arguments.is_a?(Hash)
      result = ::RailsToolViews.dispatch(params[:surface_id], scope: admin_scope, action: input["action_name"],
        arguments: arguments, base_revision: revision.to_i, idempotency_key: input["idempotency_key"],
        source_component: input["source_component"])
      respond_to do |format|
        format.turbo_stream do
          @surface = ::RailsToolViews.restore(result[:surface_id], scope: admin_scope)
          @surface_scope = admin_scope
          render turbo_stream: turbo_stream.replace(@surface.dom_id, helpers.admin_surface(@surface, scope: admin_scope))
        end
        format.html { redirect_to surface_return_path(result[:surface_id]), status: :see_other }
      end
    rescue ::RailsToolViews::Error => error
      reject(error)
    end

    private

    def tool_views
      require "rails_ai_admin/integrations/tool_views"
      Integrations::ToolViews
    end

    def require_surfaces
      raise AccessDenied unless RailsAiAdmin.configuration.surfaces
      tool_views.ensure_registered!
    end

    def bind_admin_context(&block)
      tool_views.with_context(@context, &block)
    end

    def admin_scope = @admin_scope ||= tool_views.scope_for(@context)

    # A review shown in a conversation returns there, so confirming or
    # dismissing keeps the person in the chat (RAA-019).
    def surface_return_path(surface_id)
      reference = ::RailsToolViews::Surface.where(id: surface_id).pick(:context_ref)
      chat_ref = reference.is_a?(String) && reference[/\Araa:chat:([0-9a-f-]{36})\z/, 1]
      if chat_ref && RailsAiAdmin.configuration.assistant
        require "rails_ai_admin/assistant"
        chat = Assistant::Chat.owned(@context, chat_ref)
        return assistant_conversation_path(chat_ref: chat.ref) if chat
      end
      admin_surface_path(surface_id: surface_id)
    end

    def confirmed_input
      value = params[:confirmed_input]
      raise AccessDenied, "INVALID_QUERY" unless value.is_a?(String) && value.bytesize <= Integrations::ToolViews::MAX_INPUT_BYTES
      parsed = JSON.parse(value)
      raise AccessDenied, "INVALID_QUERY" unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError
      raise AccessDenied, "INVALID_QUERY"
    end

    # Unknown, foreign or unauthorized Surfaces all look missing. A stale
    # revision or business-level rejection re-renders the saved Surface.
    def reject(error)
      case error.code
      when "NOT_FOUND", "NOT_ALLOWED", "INVALID_SCOPE", "SURFACE_PURGED" then admin_status(:not_found)
      when "CONFLICT", "IDEMPOTENCY_CONFLICT", "SURFACE_CLOSED", "OPERATION_FAILED", "RATE_LIMITED"
        @surface = ::RailsToolViews.restore(params[:surface_id], scope: admin_scope)
        @surface_scope = admin_scope
        @surface_error = error
        render :show, status: error.status
      when "INCOMPATIBLE_COMPONENT" then admin_status(:unavailable)
      else admin_status(:invalid_request)
      end
    rescue ::RailsToolViews::Error
      admin_status(:not_found)
    end
  end
end
