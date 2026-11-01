# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/operations"
require "rails_ai_admin/integrations/propose_operation"

# SPIKE-02 offline: a real RubyLLM tool loop proposes an operation and presents
# the review Surface. Only HTTP is stubbed; no provider or network is used.
class AssistantProposalsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers

  COMPLETIONS = "https://api.openai.com/v1/chat/completions"

  def setup
    reset_database
    [ RailsToolViews::AgentInteraction, RailsToolViews::ActionExecution, RailsToolViews::Presentation, RailsToolViews::Surface ].each(&:delete_all)
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
    WebMock.reset!
  end

  def with_assistant
    with_operations do
      RailsAiAdmin.configuration.surfaces = true
      yield
    end
  end

  def tool(actor: 1, conversation: "raa:conversation:c1")
    RailsAiAdmin::Integrations::ProposeOperation.new(context: context(actor: actor), conversation: conversation)
  end

  def propose(tool, id: "call_1", **arguments)
    arguments = { resource: "contract_customers", record: @customer.id.to_s, operation: "review", input: { "note" => "Reviewed by assistant" } }.merge(arguments)
    tool.call(**arguments, tool_call: RubyLLM::ToolCall.new(id: id, name: tool.name, arguments: arguments.stringify_keys))
  end

  def test_a_tool_call_proposes_and_presents_one_review_without_writing
    with_assistant do
      tool = tool()
      schema = tool.parameters_schema
      assert_equal [ "contract_customers" ], schema.dig("properties", "resource", "enum")
      assert_equal [ "review" ], schema.dig("properties", "operation", "enum"), "only operations opted in with assistant: true"
      assert_includes tool.description, "contract_customers.review"
      result = propose(tool)
      assert_equal "presented", result[:status]
      assert_equal "Alice", @customer.reload.name
      run = RailsAiAdmin::OperationRun.find_by!(origin: "assistant")
      assert_equal [ "proposed", "contract_customers", "review", @customer.id.to_s ], [ run.status, run.resource_key, run.operation, run.target_id ]
      surface = RailsToolViews::Surface.find(result[:surface_id])
      assert_equal [ context.actor_ref, "raa:conversation:c1", run.id ], [ surface.actor_ref, surface.context_ref, surface.props["intent"] ]

      assert_equal result, propose(tool), "replaying the same tool call presents the same review"
      assert_equal 1, RailsAiAdmin::OperationRun.where(origin: "assistant").count
      other = propose(tool, id: "call_2")
      refute_equal result[:surface_id], other[:surface_id]
      conflict = propose(tool, input: { "note" => "Different text" })
      assert_equal [ "rejected", "IDEMPOTENCY_CONFLICT" ], conflict.values_at(:status, :code)
    end
  end

  def test_only_the_humans_surface_submission_executes_the_proposal
    with_assistant do
      tool = tool()
      result = propose(tool)
      get "/backoffice/assistant/surfaces/#{result[:surface_id]}"
      assert_response :success
      assert_select "p", text: /An assistant proposed this/
      fields = css_select("form[action$='/actions'] input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
      post "/backoffice/assistant/surfaces/#{result[:surface_id]}/actions", params: fields
      assert_response :see_other
      assert_equal [ "Reviewed by assistant", 1 ], [ @customer.reload.name, @customer.points ]
      run = RailsAiAdmin::OperationRun.find_by!(origin: "assistant")
      assert_equal [ "succeeded", context.actor_ref ], [ run.status, run.approved_by_ref ]
      assert_equal [ "surface" ], RailsAiAdmin::AuditEvent.where(correlation_ref: run.id, status: "succeeded").pluck(:origin)
      assert_equal "reviewed", propose(tool)[:status], "a crash replay after confirmation does not ask again"
      refute RailsAiAdmin::Integrations::ProposeOperation.instance_methods.include?(:confirm)
    end
  end

  def test_untrusted_arguments_and_missing_authority_are_rejected_without_detail
    with_assistant do
      tool = tool()
      [
        { operation: "invalid" }, { resource: "uuid_customers" }, { record: @other.id.to_s }, { record: "../1" },
        { record: "999999" }, { input: "note" }
      ].each do |arguments|
        result = propose(tool, id: "call_#{arguments.keys.first}_#{arguments.values.first}", **arguments)
        assert_equal [ "rejected", "NOT_FOUND" ], result.values_at(:status, :code), arguments.inspect
        refute_includes result.to_s, "Other tenant"
      end
      invalid = propose(tool, id: "call_invalid_input", input: { "hidden_counter" => "3" })
      assert_equal [ "rejected", "VALIDATION_FAILED", [ "note" ] ], invalid.values_at(:status, :code, :fields)
      bare = tool.call(resource: "contract_customers", record: @customer.id.to_s, operation: "review", input: { "note" => "x" })
      assert_equal "INVALID_TOOL_CALL", bare[:code], "a direct call without a server ToolCall cannot propose"
      forged = tool.call(resource: "contract_customers", record: @customer.id.to_s, operation: "review", input: { "note" => "x" },
        tool_call: RubyLLM::ToolCall.new(id: "call_x", name: "present_ui", arguments: {}))
      assert_equal "INVALID_TOOL_CALL", forged[:code]
      assert_equal "rejected", propose(tool(actor: 2), id: "call_actor_2")[:status], "the reviewer's own action grant still applies"
      assert_empty RailsToolViews::Surface.all
      OperationContractPolicy.denied = true
      assert_empty tool().catalog, "a new tool for a revoked actor offers nothing"
      assert_raises(RailsAiAdmin::ConfigurationError) { tool(conversation: "conversation-1") }
      assert_raises(RailsAiAdmin::ConfigurationError) do
        Class.new(RailsAiAdmin::Resource) { operation :sample, handler: "ReviewContractOperation", assistant: true }
      end
      assert_raises(RailsAiAdmin::ConfigurationError) do
        RailsAiAdmin::Operations::Runner.new.preflight(context: context, resource: ContractCustomerAdmin, operation: :review,
          target_id: @customer.id, expected_version: 0, input: { "note" => "x" }, origin: :assistant, intent_id: "not-a-uuid")
      end
    end
  end

  def test_an_offline_ruby_llm_loop_proposes_through_the_real_tool_runtime
    with_assistant do
      arguments = { resource: "contract_customers", record: @customer.id.to_s, operation: "review", input: { note: "Reviewed through RubyLLM" } }
      tool_turn = { id: "chatcmpl-1", object: "chat.completion", model: "gpt-4.1-mini",
        choices: [ { index: 0, finish_reason: "tool_calls", message: { role: "assistant", content: nil,
          tool_calls: [ { id: "call_llm_1", type: "function", function: { name: "raa_propose_operation", arguments: arguments.to_json } } ] } } ],
        usage: { prompt_tokens: 50, completion_tokens: 20, total_tokens: 70 } }
      final_turn = { id: "chatcmpl-2", object: "chat.completion", model: "gpt-4.1-mini",
        choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: "I opened a review for you to confirm." } } ],
        usage: { prompt_tokens: 80, completion_tokens: 10, total_tokens: 90 } }
      requests = []
      stub_request(:post, COMPLETIONS).to_return do |request|
        requests << JSON.parse(request.body)
        { status: 200, headers: { "Content-Type" => "application/json" }, body: (requests.size == 1 ? tool_turn : final_turn).to_json }
      end
      global = RubyLLM.config
      chat = RubyLLM.context { |config| config.openai_api_key = "synthetic-offline-key" }
        .chat(model: "gpt-4.1-mini", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
        .with_tools(tool)
      response = chat.ask("Please mark Alice as reviewed.")

      assert_equal "I opened a review for you to confirm.", response.content
      assert_equal 2, requests.size
      offered = requests.first.fetch("tools").map { |entry| entry.dig("function", "name") }
      assert_equal [ "raa_propose_operation" ], offered
      tool_result = requests.last.fetch("messages").find { |message| message["role"] == "tool" }
      assert_equal "call_llm_1", tool_result["tool_call_id"]
      assert_equal "presented", JSON.parse(tool_result["content"]).fetch("status")
      assert_equal "Alice", @customer.reload.name, "the model's turn never writes"
      run = RailsAiAdmin::OperationRun.find_by!(origin: "assistant")
      assert_equal "proposed", run.status
      assert RailsToolViews::Surface.exists?(context_ref: "raa:conversation:c1", actor_ref: context.actor_ref)
      assert_same global, RubyLLM.config, "the admin used an isolated RubyLLM.context"
      assert_requested(:post, COMPLETIONS, times: 2)
    end
  end
end
