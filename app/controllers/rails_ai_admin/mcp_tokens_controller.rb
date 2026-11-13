# frozen_string_literal: true

module RailsAiAdmin
  # Personal access tokens for MCP clients. A new token is shown once, in the
  # response that created it; the list shows names and dates only.
  class McpTokensController < ApplicationController
    before_action :require_mcp

    def index
      load_tokens
    end

    def create
      @record, @token = Mcp::AccessToken.issue!(@context, name: params[:name], lifetime: params[:lifetime])
      load_tokens
      render :index, status: :created
    rescue AccessDenied => error
      raise unless error.code == "INVALID_QUERY"
      @problem = t("rails_ai_admin.mcp.invalid")
      load_tokens
      render :index, status: :unprocessable_content
    end

    def revoke
      token = Mcp::AccessToken.for_owner(@context).find_by(id: params[:id])
      raise AccessDenied unless token
      token.update!(revoked_at: Time.current) if token.revoked_at.nil?
      redirect_to mcp_tokens_path, status: :see_other, notice: t("rails_ai_admin.mcp.revoked")
    end

    private

    def require_mcp
      raise AccessDenied unless RailsAiAdmin.configuration.mcp
      require "rails_ai_admin/assistant"
      require "rails_ai_admin/mcp"
      raise AccessDenied unless Assistant.available?(@context)
    end

    def load_tokens
      @tokens = Mcp::AccessToken.for_owner(@context).order(created_at: :desc).limit(50).to_a
      @endpoint = mcp_url
    end
  end
end
