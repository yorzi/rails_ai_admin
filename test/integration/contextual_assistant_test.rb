# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# E01 — Contextual Assistant: server-signed PageContext snapshots and shell drawer.
class ContextualCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :contextual_customers
  title :name
  fields do
    id :id
    text :name, searchable: :contains, sortable: true
    integer :points, filterable: true
    boolean :active, filterable: true
  end
end

class ContextualAssistantPolicy < AssistantPolicy
  class_attribute :allow_filter, default: true

  def assistant?(context:, resource:)
    !denied && exposed && resource.key == :contextual_customers
  end

  def select_records?(context:, resource:) = !denied && resource.key == :contextual_customers

  def fields(context:, resource:, action:, record: nil)
    return [] if denied
    case action
    when :read then %i[id name points active]
    when :search then [ :name ]
    when :sort then [ :name ]
    when :filter then allow_filter ? %i[points active] : []
    else []
    end
  end
end

class ContextualAssistantTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  RESOURCES = %w[ContextualCustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    ContextualAssistantPolicy.allow_filter = true
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
    AssistantPolicy.exposed = true
    ContextualAssistantPolicy.allow_filter = true
  end

  def with_contextual_assistant(&block)
    with_assistant(resources: RESOURCES, policy: "ContextualAssistantPolicy", &block)
  end

  def test_conventional_pages_render_no_drawer_when_assistant_is_disabled
    get "/backoffice/customers"
    assert_response :success
    assert_select "#raa-assistant-drawer", count: 0
    assert_select ".raa-drawer-toggle", count: 0
  end

  def test_list_record_and_selection_pages_issue_signed_page_context_in_the_drawer
    with_contextual_assistant do
      get "/backoffice/contextual_customers", params: { q: "Alice", filter: { points: { gte: "5" } } }
      assert_response :success
      assert_select "body[data-controller~='raa-drawer']"
      assert_select "button.raa-drawer-toggle[aria-controls='raa-assistant-drawer']"
      drawer = css_select("#raa-assistant-drawer").first
      assert drawer
      list_token = drawer["data-page-context-token"]
      assert list_token.present?
      assert_includes drawer["data-page-context-label"], "Contextual customers"
      assert_includes drawer["data-page-context-label"], "Alice"

      post "/backoffice/assistant/conversations", params: { drawer: "1", page_context: list_token, content: "Summarize these" }
      assert_response :see_other
      assert_match %r{/backoffice/assistant/drawer\?chat_ref=[0-9a-f-]{36}\z}, response.location
      chat_ref = response.location[/chat_ref=([0-9a-f-]{36})/, 1]
      chat = RailsAiAdmin::Assistant::Chat.find_by!(ref: chat_ref)
      turn = chat.turns.first
      assert_includes turn.content, "Context: I am looking at the Contextual customers list (the contextual_customers resource), searching for \"Alice\", filtered by points gte 5."
      assert_includes turn.content, "Summarize these"

      # Revoking the filter grant drops the ungranted filter when the list token resolves.
      ContextualAssistantPolicy.allow_filter = false
      resolved = RailsAiAdmin::Assistant::PageContext.resolve!(context: context, token: list_token)
      refute_includes resolved.summary, "points gte 5"
      ContextualAssistantPolicy.allow_filter = true

      get response.location, headers: { "Turbo-Frame" => "raa_assistant_drawer" }
      assert_response :success
      assert_select "turbo-frame#raa_assistant_drawer[data-chat-ref='#{chat_ref}']"
      assert_select "form[action='/backoffice/assistant/conversations/#{chat_ref}/messages'] input[name='drawer'][value='1']"

      # Navigate to a record page and send a follow-up with the record's PageContext.
      get "/backoffice/contextual_customers/#{@customer.id}"
      assert_response :success
      record_token = css_select("#raa-assistant-drawer").first["data-page-context-token"]
      assert record_token.present?
      get "/backoffice/assistant/drawer", params: { chat_ref: chat_ref }, headers: { "Turbo-Frame" => "raa_assistant_drawer" }
      admission_key = css_select("input[name='admission_key']").first["value"]
      post "/backoffice/assistant/conversations/#{chat_ref}/messages",
        params: { drawer: "1", admission_key: admission_key, page_context: record_token, content: "Who updated this?" }
      assert_response :see_other
      follow_up = chat.turns.reorder(:sequence).last
      assert_includes follow_up.content, "Context: I am looking at Contextual customer #{@customer.id} (\"Alice\") in the contextual_customers resource."
      assert_includes follow_up.content, "Who updated this?"
    end
  end

  def test_selection_capture_and_selection_page_context_flow
    with_contextual_assistant do
      post "/backoffice/contextual_customers/selections", params: { target_ids: [ @customer.id.to_s ], then: "assistant" }
      assert_response :see_other
      assert_match %r{/backoffice/selections/[0-9a-f-]{36}\?open_assistant=1\z}, response.location

      get response.location
      assert_response :success
      drawer = css_select("#raa-assistant-drawer").first
      selection_token = drawer["data-page-context-token"]
      assert selection_token.present?
      assert_equal "Contextual customers · 1 selected", drawer["data-page-context-label"]

      post "/backoffice/assistant/conversations", params: { drawer: "1", page_context: selection_token, content: "Compare these" }
      assert_response :see_other
      chat_ref = response.location[/chat_ref=([0-9a-f-]{36})/, 1]
      turn = RailsAiAdmin::Assistant::Chat.find_by!(ref: chat_ref).turns.first
      assert_includes turn.content, "Context: I am looking at a fixed selection of 1 Contextual customers in the contextual_customers resource (IDs: #{@customer.id})."
    end
  end

  def test_tampered_foreign_stale_or_revoked_page_context_fails_closed
    with_contextual_assistant do
      get "/backoffice/contextual_customers/#{@customer.id}"
      assert_response :success
      token = css_select("#raa-assistant-drawer").first["data-page-context-token"]
      assert token.present?

      # 1. Tampered token is rejected without creating a chat.
      before_count = RailsAiAdmin::Assistant::Chat.count
      post "/backoffice/assistant/conversations", params: { drawer: "1", page_context: "#{token}tamper", content: "Hello" }
      assert_response :not_found
      assert_equal before_count, RailsAiAdmin::Assistant::Chat.count

      # 2. Foreign actor cannot use actor 1's PageContext token.
      post "/test/sign_in/2"
      post "/backoffice/assistant/conversations", params: { drawer: "1", page_context: token, content: "Hello" }
      assert_response :not_found
      assert_equal before_count, RailsAiAdmin::Assistant::Chat.count

      # 3. Foreign tenant cannot use tenant 1's PageContext token.
      assert_raises(RailsAiAdmin::AccessDenied) do
        RailsAiAdmin::Assistant::PageContext.resolve!(context: context(tenant: 2), token: token)
      end

      # 4. Stale security_version cannot use an earlier PageContext token.
      assert_raises(RailsAiAdmin::AccessDenied) do
        RailsAiAdmin::Assistant::PageContext.resolve!(context: context(version: "2"), token: token)
      end

      # 5. Revoked assistant grant fails closed even with valid actor/tenant/version.
      post "/test/sign_in/1"
      AssistantPolicy.exposed = false
      assert_raises(RailsAiAdmin::AccessDenied) do
        RailsAiAdmin::Assistant::PageContext.resolve!(context: context, token: token)
      end
    end
  end

  def test_expired_selection_page_context_fails_closed
    with_contextual_assistant do
      selection = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: ContextualCustomerAdmin, target_ids: [ @customer.id.to_s ])
      issued = RailsAiAdmin::Assistant::PageContext.issue(context: context, resource: ContextualCustomerAdmin, selection: selection)
      assert issued
      RailsAiAdmin::Selection.where(id: selection.selection_ref).update_all(expires_at: 1.minute.ago)
      assert_raises(RailsAiAdmin::AccessDenied) do
        RailsAiAdmin::Assistant::PageContext.resolve!(context: context, token: issued.token)
      end
    end
  end
end
