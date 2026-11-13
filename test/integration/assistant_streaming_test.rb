# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# Replies stream into the turn's draft while the provider writes them.
class AssistantStreamingTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  Coordinator = RailsAiAdmin::Assistant::Coordinator

  def setup
    reset_database
    reset_assistant
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def test_the_worker_saves_streamed_text_and_clears_it_when_the_message_is_saved
    with_assistant do
      chat = new_chat
      turn = admit(chat, "Tell me about Alice")
      LLMFixture.reply("Alice is a customer with no points yet, as far as I can see.")
      saved = []
      original = Coordinator.instance_method(:save_draft)
      Coordinator.define_method(:save_draft) do |claim, text|
        saved << text
        original.bind_call(self, claim, text)
      end
      begin
        drain(chat)
      ensure
        Coordinator.define_method(:save_draft, original)
      end
      assert LLMFixture.requests.first["stream"], "the provider is asked to stream"
      partial = saved.compact
      assert partial.any?, "text was saved while streaming"
      assert "Alice is a customer with no points yet, as far as I can see.".start_with?(partial.first)
      assert_nil saved.last, "the draft is cleared once the message is saved"
      assert_nil turn.reload.draft
      assert_equal "completed", turn.status
      assert_equal "Alice is a customer with no points yet, as far as I can see.", chat.messages.where(role: "assistant").last.content
    end
  end

  # Model text is plain text: markup from a reply (or injected through record
  # data) is shown as characters, never as links or formatting.
  def test_replies_render_markup_as_text
    with_assistant do
      chat = new_chat
      admit(chat, "Hi")
      LLMFixture.reply(%(See <a href="https://evil.example/">this</a> and <img src="https://evil.example/x.png">))
      drain(chat)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select ".raa-chat-assistant a[href^='https://evil']", count: 0
      assert_select ".raa-chat-assistant img", count: 0
      assert_select ".raa-chat-assistant", text: /See <a href="https:\/\/evil.example\/">this<\/a>/
    end
  end

  def test_a_running_turn_shows_its_draft_and_polls_faster_and_a_fenced_worker_writes_nothing
    with_assistant do
      chat = new_chat
      turn = admit(chat, "Hello")
      turn.update!(status: "running", lease_owner: "owner-1", generation: 1, lease_expires_at: 5.minutes.from_now, draft: "Partial <b>answer</b>")
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_select "li.raa-chat-streaming[aria-busy=true]", text: /Partial <b>answer<\/b>/
      refute_includes response.body, "<b>answer</b>"
      assert_select "[data-raa-pending=streaming]"

      stale = Coordinator::Claim.new(turn.id, chat.id, "owner-0", 0)
      Coordinator.new.save_draft(stale, "Late text")
      assert_equal "Partial <b>answer</b>", turn.reload.draft, "only the lease holder may write the draft"

      OperationJobContext.epoch = "2"
      get "/backoffice/assistant/conversations/#{chat.ref}"
      refute_includes response.body, "Partial", "a closed chat shows no draft"
    end
  end
end
