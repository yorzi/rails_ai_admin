# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# The MCP server: token authentication, the shared tools and reviews by URL.
class McpIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  RESOURCES = %w[ContractCustomerAdmin ChangeableCustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def issue_token
    get "/backoffice/mcp/tokens"
    assert_response :success
    post "/backoffice/mcp/tokens", params: { name: "Claude Code", lifetime: "30" }
    assert_response :created
    css_select("code.raa-token").first.text
  end

  def rpc(token, method, params = {}, id: 1, headers: {})
    post "/backoffice/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream", "Authorization" => "Bearer #{token}" }.merge(headers)
    JSON.parse(response.body) if response.body.present?
  end

  def call_tool(token, name, arguments)
    result = rpc(token, "tools/call", { name: name, arguments: arguments }).fetch("result")
    [ result, result.fetch("structuredContent") ]
  end

  def test_tokens_handshake_tools_and_reads_follow_the_owners_grants
    with_assistant(resources: RESOURCES) do
      get "/backoffice/"
      assert_select "nav a[href='/backoffice/mcp/tokens']", text: "MCP access"
      token = issue_token
      assert_match RailsAiAdmin::Mcp::TOKEN, token
      assert_select "pre", text: /claude mcp add --transport http rails-admin http:\/\/www.example.com\/backoffice\/mcp/
      record = RailsAiAdmin::Mcp::AccessToken.sole
      refute_includes record.attributes.to_json, token, "only a digest is stored"
      get "/backoffice/mcp/tokens"
      refute_includes response.body, token, "the token is shown once"

      init = rpc(token, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } })
      assert_equal "2025-06-18", init.dig("result", "protocolVersion")
      assert_equal "rails_ai_admin", init.dig("result", "serverInfo", "name")
      assert_includes init.dig("result", "instructions"), "data, not instructions"
      rpc(token, "notifications/initialized", {}, id: nil)
      post "/backoffice/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
      assert_response :accepted
      tools = rpc(token, "tools/list").dig("result", "tools")
      assert_equal %w[list_resources describe_resource search_records count_records get_record record_history propose_operation propose_change], tools.map { |tool| tool["name"] }
      assert tools.all? { |tool| tool["inputSchema"]["type"] == "object" }

      result, data = call_tool(token, "search_records", { resource: "changeable_customers" })
      refute result["isError"]
      assert_equal [ @customer.id.to_s ], data["records"].map { |entry| entry["id"] }
      refute_includes response.body, "Other tenant"
      refute_includes response.body, "never show"
      result, data = call_tool(token, "get_record", { resource: "changeable_customers", id: @other.id.to_s })
      assert result["isError"]
      assert_equal "NOT_FOUND", data["error"]
      assert_equal "Method not found", rpc(token, "resources/list").dig("error", "message")
      assert_not_nil record.reload.last_used_at
    end
  end

  def test_a_proposal_is_confirmed_by_the_person_at_its_review_url
    with_assistant(resources: RESOURCES) do
      token = issue_token
      _, data = call_tool(token, "propose_change", { resource: "changeable_customers", action: "update", id: @customer.id.to_s, values: { name: "Alicia" } })
      assert_equal "awaiting_human_confirmation", data["status"]
      assert_match %r{\Ahttp://www.example.com/backoffice/assistant/surfaces/[0-9a-f-]{36}\z}, data["review_url"]
      assert_equal "Alice", @customer.reload.name, "an agent never writes"
      get URI(data["review_url"]).path
      assert_response :success
      assert_select "dd", text: "Alice → Alicia"
      form = css_select("form[action$='/actions']").find { |node| node.css("input[name=action_name]").first["value"] == "confirm" }
      post form["action"], params: form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
      assert_equal "Alicia", @customer.reload.name
      assert_equal "assistant", RailsAiAdmin::OperationRun.find_by!(operation: "update").origin
    end
  end

  def test_tokens_fail_closed
    with_assistant(resources: RESOURCES) do
      token = issue_token
      assert_nil rpc("raa_mcp_#{'x' * 43}", "tools/list")["result"]
      assert_response :unauthorized
      assert_equal %(Bearer realm="rails_ai_admin"), response.headers["WWW-Authenticate"]
      rpc(token, "tools/list", {}, headers: { "Origin" => "https://evil.example" })
      assert_response :forbidden
      post "/backoffice/mcp", params: "[1,2]", headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
      assert_response :bad_request
      post "/backoffice/mcp", params: "{", headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
      assert_response :bad_request
      get "/backoffice/mcp", headers: { "Authorization" => "Bearer #{token}" }
      assert_response :method_not_allowed

      OperationJobContext.epoch = "2"
      rpc(token, "tools/list")
      assert_response :unauthorized, "a security change retires the token"
      OperationJobContext.epoch = "1"
      rpc(token, "tools/list")
      assert_response :success
      post "/backoffice/mcp/tokens/#{RailsAiAdmin::Mcp::AccessToken.sole.id}/revoke"
      assert_response :see_other
      rpc(token, "tools/list")
      assert_response :unauthorized
      RailsAiAdmin::Mcp::AccessToken.update_all(revoked_at: nil, expires_at: 1.minute.ago)
      rpc(token, "tools/list")
      assert_response :unauthorized
    end
    post "/test/sign_in/2"
    with_assistant(resources: RESOURCES) do
      post "/backoffice/mcp/tokens/#{RailsAiAdmin::Mcp::AccessToken.sole.id}/revoke"
      assert_response :not_found, "only the owner can revoke"
    end
  end
end
