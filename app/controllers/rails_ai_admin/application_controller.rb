# frozen_string_literal: true

module RailsAiAdmin
  # Resolves fresh host authority for every request without altering host classes.
  class ApplicationController < ActionController::Base
    # Routing metadata is useful; arbitrary inputs and search text are not logs.
    LOG_FILTER = /\A(?!(?:controller|action|resource|id|format)\z)/
    protect_from_forgery with: :exception
    wrap_parameters false
    layout "rails_ai_admin/application"
    before_action :secure_headers
    before_action :authenticate_admin
    helper_method :visible_resources, :allowed_action?, :record_label, :collection_jobs_available?

    rescue_from AccessDenied, with: :deny_access
    rescue_from ConfigurationError do
      render plain: "Administration is not configured safely. Contact the host maintainer.", status: :service_unavailable
    end
    rescue_from ActionController::InvalidAuthenticityToken do
      render plain: "Invalid request", status: :unprocessable_content
    end

    private

    def process_action(*)
      filters = Array(request.get_header("action_dispatch.parameter_filter")) + [ LOG_FILTER ]
      request.set_header("action_dispatch.parameter_filter", filters)
      super
    end

    def secure_headers
      @admin_csp_nonce = SecureRandom.base64(24)
      response.headers["Cache-Control"] = "no-store, private"
      response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'nonce-#{@admin_csp_nonce}'; img-src 'self' data:; connect-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "same-origin"
    end

    def authenticate_admin
      name = RailsAiAdmin.configuration.context_adapter
      @context = name&.constantize&.new&.resolve(self)
      raise AccessDenied, "UNAUTHENTICATED" unless @context.is_a?(Context)
    end

    def deny_access(error)
      status = case error.code
      when "UNAUTHENTICATED" then :unauthorized
      when "INVALID_QUERY" then :unprocessable_content
      when "CONFLICT", "SELECTION_EXPIRED", "SELECTION_INVALIDATED" then :conflict
      else :not_found
      end
      message = case status
      when :unauthorized then "Authentication required"
      when :unprocessable_content then "Invalid query"
      when :conflict then "The records or request have changed. Reload and try again."
      else "Not found"
      end
      render plain: message, status: status
    end

    def visible_resources
      RailsAiAdmin.registry.resources.select do |resource|
        Authorization::Access.new(@context, resource).authorize!(:index)
      rescue AccessDenied
        false
      end
    end

    def allowed_action?(resource, action, record = nil)
      Authorization::Access.new(@context, resource).authorize!(action, record)
    rescue AccessDenied
      false
    end

    def collection_jobs_available?
      RailsAiAdmin.registry.resources.any? do |resource|
        RailsAiAdmin.operation_registry.custom(resource).any? do |definition|
          next false unless definition.scope == :collection
          Authorization::Access.new(@context, resource).authorize_receipt!(definition.key, nil)
        rescue AccessDenied
          false
        end
      end
    end

    def record_label(resource, record)
      access = Authorization::Access.new(@context, resource)
      return "Record ##{record.id}" unless allowed_action?(resource, :show, record)
      field = access.fields(:read, record).find { |candidate| candidate.name == resource.title }
      field ? access.read_value(record, field).to_s : "Record ##{record.id}"
    end
  end
end
