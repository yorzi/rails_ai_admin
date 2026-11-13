# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# The assistant proposes native creates, updates and deletes; only the
# human's confirmation of the review writes, as the human, through the Runner.
class AssistantChangesIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  RESOURCES = %w[ContractCustomerAdmin ChangeableCustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def start_chat(params = {})
    post "/backoffice/assistant/conversations", params: params
    assert_response :see_other
    RailsAiAdmin::Assistant::Chat.find_by!(ref: response.location[%r{conversations/([0-9a-f-]{36})\z}, 1])
  end

  def say(chat, text)
    get "/backoffice/assistant/conversations/#{chat.ref}"
    post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: text, admission_key: css_select("input[name=admission_key]").first["value"] }
  end

  def run_turn(*tools, reply: "Please review it.")
    tools.each { |name, arguments| LLMFixture.tool(name, arguments) }
    LLMFixture.reply(reply)
    perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
  end

  def tool_result(chat, index = -1) = JSON.parse(chat.messages.where(role: "tool").order(:id).to_a[index].content)

  def confirm(chat, action: "confirm")
    get "/backoffice/assistant/conversations/#{chat.ref}"
    form = css_select("form[action$='/actions']").find { |node| node.css("input[name=action_name]").first["value"] == action }
    post form["action"], params: form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
  end

  def test_an_update_is_reviewed_with_before_and_after_then_written_by_the_human
    with_assistant(resources: RESOURCES) do
      chat = start_chat
      say(chat, "Rename Alice to Alicia")
      run_turn([ "describe_resource", { resource: "changeable_customers" } ],
        [ "propose_change", { resource: "changeable_customers", action: "update", id: @customer.id.to_s, values: { name: "Alicia" } } ])
      described = tool_result(chat, 0)
      assert_equal [ "create", "update", "destroy" ], described["changes"].map { |change| change["action"] }
      assert_equal %w[name points], described["changes"].find { |change| change["action"] == "update" }["fields"].map { |field| field["name"] }
      assert_equal "awaiting_human_confirmation", tool_result(chat)["status"]
      assert_equal "Alice", @customer.reload.name, "the assistant never writes"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "section.rails-tool-views-surface h2", text: "Update changeable customer"
      assert_select "section.rails-tool-views-surface dd", text: "Alice → Alicia"
      assert_select "section.rails-tool-views-surface p a[href='/backoffice/changeable_customers/#{@customer.id}']", text: "Alice"
      refute_includes response.body, "&lt;a href"
      confirm(chat)
      assert_equal "Alicia", @customer.reload.name
      run = RailsAiAdmin::OperationRun.find_by!(operation: "update")
      assert_equal [ "succeeded", "assistant", context.actor_ref ], [ run.status, run.origin, run.approved_by_ref ]
      assert_equal [ "name" ], RailsAiAdmin::AuditEvent.find_by!(correlation_ref: run.id, status: "succeeded").changed_fields
      assert_includes chat.turns.find_by!(kind: "continuation").content, "confirmed \"update changeable customer\""
    end
  end

  def test_creates_and_deletes_also_wait_for_the_human
    with_assistant(resources: RESOURCES) do
      chat = start_chat
      say(chat, "Add Bea with 3 points")
      run_turn([ "propose_change", { resource: "changeable_customers", action: "create", values: { name: "Bea", points: 3 } } ])
      assert_nil Customer.find_by(name: "Bea"), "a create waits for confirmation too"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "section.rails-tool-views-surface h2", text: "Create changeable customer"
      assert_select "section.rails-tool-views-surface dd", text: "— → Bea"
      confirm(chat)
      bea = Customer.find_by!(name: "Bea", account_id: 1)
      assert_includes chat.turns.find_by!(kind: "continuation").content, "created with id #{bea.id}"

      LLMFixture.reply("Noted.")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      say(chat, "Delete Bea")
      run_turn([ "propose_change", { resource: "changeable_customers", action: "destroy", id: bea.id.to_s } ])
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "section.rails-tool-views-surface p strong", text: /cannot be undone/
      assert_select "section.rails-tool-views-surface input.raa-danger[value=Delete]"
      confirm(chat)
      refute Customer.exists?(bea.id)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select "section.rails-tool-views-surface p", text: /Changeable customer ##{bea.id}/
    end
  end

  def test_unallowed_invalid_and_stale_proposals_change_nothing
    with_assistant(resources: RESOURCES) do
      chat = start_chat
      say(chat, "Try things")
      run_turn([ "propose_change", { resource: "contract_customers", action: "update", id: @customer.id.to_s, values: { name: "X" } } ],
        [ "propose_change", { resource: "changeable_customers", action: "create", values: { name: "Typed", points: "many" } } ],
        [ "propose_change", { resource: "changeable_customers", action: "update", id: @customer.id.to_s, values: { secret: "x" } } ],
        [ "propose_change", { resource: "changeable_customers", action: "update", id: @other.id.to_s, values: { name: "X" } } ],
        [ "propose_change", { resource: "changeable_customers", action: "destroy", id: @customer.id.to_s, values: { name: "X" } } ],
        [ "propose_change", { resource: "changeable_customers", action: "update", id: @customer.id.to_s, values: { name: "Late" } } ])
      results = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content) }
      assert_equal "NOT_FOUND", results[0]["error"], "contract_customers does not allow native changes"
      assert_equal "VALIDATION_FAILED", results[1]["error"]
      assert_equal [ "points" ], results[1]["fields"].keys
      assert_equal "VALIDATION_FAILED", results[2]["error"], "secret is not writable"
      assert_equal "NOT_FOUND", results[3]["error"], "another tenant's record"
      assert_equal "INVALID_QUERY", results[4]["error"]
      assert_equal "awaiting_human_confirmation", results[5]["status"]
      @customer.update!(name: "Changed elsewhere")
      confirm(chat)
      assert_equal "Changed elsewhere", @customer.reload.name, "a stale review conflicts instead of overwriting"
      assert_equal 1, RailsAiAdmin::OperationRun.where(origin: "assistant").count
    end
  end

  def test_history_tool_and_page_context
    with_assistant(resources: RESOURCES) do
      chat = start_chat(content: "Who changed this?", about: { resource: "changeable_customers", id: @customer.id.to_s })
      first = chat.turns.order(:sequence).first
      assert first.content.start_with?("Context: I am looking at Changeable customer #{@customer.id} (\"Alice\") in the changeable_customers resource.")
      assert first.content.end_with?("Who changed this?")
      run_turn([ "record_history", { resource: "changeable_customers", id: @customer.id.to_s } ], reply: "Nobody yet.")
      assert_equal [], tool_result(chat)["changes"]

      foreign = start_chat(content: "And this?", about: { resource: "changeable_customers", id: @other.id.to_s })
      assert_equal "And this?", foreign.turns.first.content, "a page the user cannot open adds no context"
      listed = start_chat(content: "How many?", about: { resource: "changeable_customers", q: "Ali" })
      assert_includes listed.turns.first.content, "list (the changeable_customers resource), searching for \"Ali\""

      get "/backoffice/changeable_customers/#{@customer.id}"
      assert_select "details.raa-ask form[action='/backoffice/assistant/conversations'] input[name='about[id]'][value='#{@customer.id}']"
      get "/backoffice/changeable_customers"
      assert_select "details.raa-ask summary", text: "Ask the assistant about this list"
    end
  end
end
