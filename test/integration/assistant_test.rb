# frozen_string_literal: true

require "test_helper"
require "support/assistant"

class AssistantIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  def setup
    reset_database
    reset_assistant
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def start_chat
    post "/backoffice/assistant/conversations"
    assert_response :see_other
    ref = response.location[%r{/backoffice/assistant/conversations/([0-9a-f-]{36})\z}, 1]
    assert ref, response.location
    RailsAiAdmin::Assistant::Chat.find_by!(ref: ref)
  end

  def say(chat, text)
    get "/backoffice/assistant/conversations/#{chat.ref}"
    key = css_select("input[name=admission_key]").first["value"]
    post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: text, admission_key: key }
    assert_response :see_other
    key
  end

  def surface_fields
    css_select("form[action$='/actions'] input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
  end

  def test_chat_to_surface_to_one_confirmed_write_and_one_continuation
    with_assistant do
      get "/backoffice"
      assert_select "nav a[href='/backoffice/assistant']", text: "Assistant"
      chat = start_chat
      key = nil
      assert_enqueued_jobs 1, only: RailsAiAdmin::AssistantTurnJob do
        key = say(chat, "Please mark Alice as reviewed")
      end
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "Please mark Alice as reviewed", admission_key: key }
      assert_equal 1, chat.turns.count, "a repeated submission of the same form is admitted once"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "[data-raa-pending]", text: /Waiting for the assistant/
      assert_select ".raa-chat-user", text: /Please mark Alice as reviewed/, count: 1
      assert_select "turbo-frame#raa_assistant_transcript form[action$='/cancel'][data-turbo-frame=_top]"
      assert_select "turbo-frame#raa_assistant_transcript[data-controller=raa-poll]"

      LLMFixture.tool("search_records", { resource: "contract_customers" })
      LLMFixture.tool("propose_operation", { resource: "contract_customers", id: @customer.id.to_s, operation: "review", input: { note: "Reviewed by assistant" } })
      LLMFixture.reply("I prepared a review. Please confirm it.")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      assert_equal "Alice", @customer.reload.name, "the assistant never writes business data"

      get "/backoffice/assistant/conversations/#{chat.ref}", headers: { "Turbo-Frame" => "raa_assistant_transcript" }
      assert_response :success
      assert_select "turbo-frame#raa_assistant_transcript"
      assert response.body.start_with?("<!DOCTYPE html>"), "frame responses stay in standards mode"
      assert_select "[data-raa-pending]", count: 0
      assert_select "form[action$='/cancel']", { count: 0 }, "Stop appears only while a turn is pending"
      assert_select ".raa-chat-user", text: /Please mark Alice as reviewed/
      assert_select ".raa-chat-activity", text: "Searched Contract customers"
      assert_select ".raa-chat-records a[href='/backoffice/contract_customers/#{@customer.id}']", text: "Alice"
      assert_select ".raa-chat-assistant", text: /I prepared a review/
      assert_select "section.rails-tool-views-surface dd", text: "Reviewed by assistant"
      fields = surface_fields
      surface_id = fields.fetch("source_component") && css_select("form[action$='/actions']").first["action"][%r{surfaces/([0-9a-f-]{36})/actions}, 1]

      assert_enqueued_jobs 1, only: RailsAiAdmin::AssistantTurnJob do
        post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      end
      assert_response :see_other
      assert_equal [ "Reviewed by assistant", 1 ], [ @customer.reload.name, @customer.points ]
      run = RailsAiAdmin::OperationRun.sole
      assert_equal [ "succeeded", "assistant" ], [ run.status, run.origin ]
      continuation = chat.turns.find_by!(kind: "continuation")
      assert_equal "intent:#{run.id}", continuation.admission_key
      assert_includes continuation.content, "The change was applied."

      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      assert_response :see_other, "the same key replays"
      assert_equal 1, chat.turns.where(kind: "continuation").count, "a replayed confirmation admits no second continuation"
      assert_equal 1, RailsAiAdmin::AuditEvent.where(correlation_ref: run.id, status: "succeeded").count

      LLMFixture.reply("Done: Alice is reviewed.")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      continuation_request = LLMFixture.requests.last["messages"].reverse.find { |message| message["role"] == "user" }
      assert_includes continuation_request["content"], "Review result"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-chat-event", text: /Review result/
      assert_select ".raa-chat-assistant", text: /Done: Alice is reviewed/
      assert_equal 0, LLMFixture.pending
    end
  end

  def test_conversations_are_private_closed_on_security_changes_and_absent_without_grants
    with_assistant do
      chat = start_chat
      say(chat, "Hello")
      LLMFixture.reply("Hi.")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      post "/test/sign_in/2"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :not_found, "another actor's conversation looks missing"
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "x", admission_key: "message:abc" }
      assert_response :not_found
      post "/test/sign_in/1"
      OperationJobContext.epoch = "2"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-notice", text: /closed because your access changed/
      assert_select ".raa-chat-assistant", { count: 0 }, "old output is not shown under a new authority"
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "Again", admission_key: "message:def" }
      assert_response :conflict
      OperationJobContext.epoch = "1"
      AssistantPolicy.exposed = false
      get "/backoffice/assistant"
      assert_response :not_found
      get "/backoffice"
      assert_select "nav a[href='/backoffice/assistant']", count: 0
    end
  end

  def test_unavailable_ai_shows_a_recoverable_state_and_retry_reuses_the_message
    with_assistant do
      TestAssistant.available = false
      chat = start_chat
      say(chat, "Hello")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-chat-failure", text: /not available right now/
      TestAssistant.available = true
      LLMFixture.reply("Back.")
      post "/backoffice/assistant/conversations/#{chat.ref}/retry"
      assert_response :see_other
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      assert_equal [ [ "user", "Hello" ], [ "assistant", "Back." ] ], transcript(chat)
      get "/backoffice/contract_customers"
      assert_response :success, "conventional pages never depend on the provider"
    end
  end

  def test_invalid_messages_keep_the_draft_and_stop_cancels_waiting_turns
    with_assistant do
      chat = start_chat
      get "/backoffice/assistant/conversations/#{chat.ref}"
      key = css_select("input[name=admission_key]").first["value"]
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "x" * 4_001, admission_key: key }
      assert_response :unprocessable_content
      assert_select "#raa-chat-error"
      assert_select "input[name=admission_key][value='#{key}']"
      say(chat, "First")
      say(chat, "Second")
      post "/backoffice/assistant/conversations/#{chat.ref}/cancel"
      assert_response :see_other
      assert_equal %w[cancelled cancelled], chat.turns.pluck(:status)
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
      assert_empty LLMFixture.requests
      post "/backoffice/assistant/conversations/#{chat.ref}/archive"
      assert_response :see_other
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-notice", text: /archived/
    end
  end
end
