# frozen_string_literal: true

module RailsAiAdmin
  # The MCP endpoint. It reads no cookie or session: a bearer token names the
  # owner, and the host's resolve_job turns that into a fresh Context.
  class McpController < ActionController::API
    before_action :prepare_headers

    def handle
      return head(:forbidden) unless same_origin?
      context, token = authenticate
      return unauthorized unless context
      require "rails_ai_admin/mcp"
      raw = request.raw_post.to_s
      return render(json: rpc_error(nil, -32600, "Request too large"), status: :payload_too_large) if raw.bytesize > Mcp::MAX_BODY
      message = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        return render(json: rpc_error(nil, -32700, "Parse error"), status: :bad_request)
      end
      return render(json: rpc_error(nil, -32600, "Batches are not supported"), status: :bad_request) if message.is_a?(Array)
      server = Mcp::Server.new(context: context, token: token,
        review_url: ->(surface_id) { admin_surface_url(surface_id: surface_id) })
      status, body = if RailsAiAdmin.configuration.surfaces
        Integrations::ToolViews.with_context(context) { server.handle(message) }
      else
        server.handle(message)
      end
      body ? render(json: body, status: status) : head(status)
    end

    # No server-initiated stream and no session to end.
    def unsupported = head(:method_not_allowed)

    private

    def prepare_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    # MCP requires rejecting cross-site browser requests (DNS rebinding).
    def same_origin?
      origin = request.headers["Origin"]
      return true if origin.blank?
      URI.parse(origin).then { |uri| uri.host == request.host && (uri.port || 80) == request.port }
    rescue URI::InvalidURIError
      false
    end

    def authenticate
      raise AccessDenied unless RailsAiAdmin.configuration.mcp
      require "rails_ai_admin/assistant"
      require "rails_ai_admin/mcp"
      require "rails_ai_admin/integrations/tool_views" if RailsAiAdmin.configuration.surfaces
      header = request.headers["Authorization"].to_s
      token = Mcp::AccessToken.authenticate(header.delete_prefix("Bearer ").strip) if header.start_with?("Bearer ")
      return [ nil, nil ] unless token
      adapter = RailsAiAdmin.configuration.context_adapter&.constantize&.new
      return [ nil, nil ] unless adapter.respond_to?(:resolve_job)
      context = ActiveRecord::Base.while_preventing_writes do
        adapter.resolve_job(actor_ref: token.actor_ref, tenant_ref: token.tenant_ref, security_version: token.security_version)
      end
      unless context.is_a?(Context) && context.actor_ref == token.actor_ref && context.tenant_ref == token.tenant_ref &&
          context.security_version == token.security_version
        return [ nil, nil ]
      end
      token.update_columns(last_used_at: Time.current) if token.last_used_at.nil? || token.last_used_at < 1.minute.ago
      [ context, token ]
    rescue AccessDenied, ActiveRecord::ReadOnlyError
      [ nil, nil ]
    end

    def unauthorized
      response.headers["WWW-Authenticate"] = %(Bearer realm="rails_ai_admin")
      render json: rpc_error(nil, -32001, "A valid admin access token is required"), status: :unauthorized
    end

    def rpc_error(id, code, message) = { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
  end
end
