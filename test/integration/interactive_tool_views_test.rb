# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# E03 Phase 1 — Read-only interactive RailsToolViews surfaces (RecordCard,
# RecordTable, MetricCard) with live re-authorization and graceful fallback.
class InteractiveCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :interactive_customers
  title :name
  fields do
    id :id
    text :name, searchable: :contains, sortable: true
    integer :points, filterable: true, aggregatable: true
    boolean :active, filterable: true
  end
  scopes do
    scope :active, -> { where(active: true) }, label: "Active"
  end
end

class InteractiveSurfacePolicy < AssistantPolicy
  class_attribute :hide_points, default: false
  class_attribute :deny_show_id, default: nil

  def assistant?(context:, resource:)
    !denied && exposed && resource.key == :interactive_customers
  end

  def allowed?(context:, action:, resource:, record: nil)
    return false if action.to_sym == :show && record && deny_show_id && record.id == deny_show_id
    super
  end

  def named_scopes(context:, resource:) = denied ? [] : %i[active]

  def fields(context:, resource:, action:, record: nil)
    return [] if denied
    case action
    when :read then hide_points ? %i[id name active] : %i[id name points active]
    when :search then [ :name ]
    when :sort then [ :name ]
    when :filter then %i[points active]
    else []
    end
  end
end

class InteractiveToolViewsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  RESOURCES = %w[InteractiveCustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    InteractiveSurfacePolicy.hide_points = false
    InteractiveSurfacePolicy.deny_show_id = nil
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
    AssistantPolicy.exposed = true
    InteractiveSurfacePolicy.hide_points = false
    InteractiveSurfacePolicy.deny_show_id = nil
  end

  def with_interactive(surfaces: true, &block)
    with_assistant(surfaces: surfaces, resources: RESOURCES, policy: "InteractiveSurfacePolicy", &block)
  end

  def ask_and_run(chat, question, *tools, reply: "Here are the results.")
    get "/backoffice/assistant/conversations/#{chat.ref}"
    key = css_select("input[name='admission_key']").first["value"]
    post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: question, admission_key: key }
    assert_response :see_other
    tools.each { |name, arguments| LLMFixture.tool(name, arguments) }
    LLMFixture.reply(reply)
    perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)
  end

  def test_record_card_renders_safely_survives_reload_and_enforces_live_grants
    @customer.update!(name: "<script>alert(1)</script> Alice", points: 42)
    with_interactive do
      chat = new_chat
      ask_and_run(chat, "Inspect Alice", [ "get_record", { resource: "interactive_customers", id: @customer.id.to_s } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-card h3 a[href='/backoffice/interactive_customers/#{@customer.id}']"
      assert_select ".raa-record-card dd", text: "42"
      refute_includes response.body, "<script>alert(1)</script>"

      tool_data = JSON.parse(chat.messages.where(role: "tool").last.content)
      surface_id = tool_data["surface"]
      assert surface_id.present?

      # Direct read works for owner, denied for another actor.
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :success
      assert_select ".raa-record-card"

      # Read-only surfaces reject every action submission.
      post "/backoffice/assistant/surfaces/#{surface_id}/actions",
        params: { action_name: "confirm", base_revision: "1", idempotency_key: SecureRandom.uuid, source_component: "raa_record_card" }
      assert_response :unprocessable_content

      # Foreign actor cannot fetch the surface.
      post "/test/sign_in/2"
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :not_found

      # Revoking a field hides it on reload without leaking old values.
      post "/test/sign_in/1"
      InteractiveSurfacePolicy.hide_points = true
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-card dt", text: "Points", count: 0

      # Revoking :show hides the entire record card on reload.
      InteractiveSurfacePolicy.deny_show_id = @customer.id
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-card", count: 0
    end
  end

  def test_record_table_renders_live_rows_and_falls_back_when_surfaces_are_off
    bob = Customer.create!(account_id: 1, name: "Bob", points: 15, active: true)
    with_interactive(surfaces: true) do
      chat = new_chat
      ask_and_run(chat, "Find active customers", [ "search_records", { resource: "interactive_customers", query: "Bob" } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-table table td.raa-cell-title a[href='/backoffice/interactive_customers/#{bob.id}']", text: "Bob"
      assert_select ".raa-record-table .raa-surface-meta", text: /1 record shown/

      # Revoking :show on Bob omits Bob on reload.
      InteractiveSurfacePolicy.deny_show_id = bob.id
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-table td.raa-cell-title a", count: 0
      assert_select ".raa-record-table .raa-surface-meta", text: /1 record omitted/
    end

    # Graceful fallback when config.surfaces == false.
    InteractiveSurfacePolicy.deny_show_id = nil
    with_interactive(surfaces: false) do
      chat = new_chat
      ask_and_run(chat, "Find Bob without surfaces", [ "search_records", { resource: "interactive_customers", query: "Bob" } ])
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-record-table", count: 0
      assert_select ".raa-chat-records a[href='/backoffice/interactive_customers/#{bob.id}']", text: "Bob"
    end
  end

  # The common case: one total, no breakdown (recorded totals scenario).
  def test_metric_card_shows_an_ungrouped_total
    Customer.create!(account_id: 1, name: "Bob", points: 40, active: false)
    @customer.update!(points: 10, active: true)
    with_interactive do
      chat = new_chat
      ask_and_run(chat, "Total points",
        [ "aggregate_records", { resource: "interactive_customers", function: "sum", field: "points" } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".rails-tool-views-error", count: 0
      assert_select ".raa-metric-card .raa-metric-value", text: "50"
      assert_select ".raa-metric-card table", count: 0
    end
  end

  # A named list tab is shown on the card; "scope" is also I18n's own option.
  def test_cards_name_the_list_tab_they_used
    Customer.create!(account_id: 1, name: "Bob", points: 40, active: false)
    @customer.update!(points: 10, active: true)
    with_interactive do
      chat = new_chat
      ask_and_run(chat, "Total points of active customers",
        [ "aggregate_records", { resource: "interactive_customers", function: "sum", field: "points", scope: "active" } ],
        [ "search_records", { resource: "interactive_customers", scope: "active" } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".rails-tool-views-error", count: 0
      assert_select ".raa-metric-card .raa-metric-value", text: "10"
      assert_select ".raa-metric-card .raa-surface-meta", text: /tab: active/
      assert_select ".raa-record-table .raa-surface-meta", text: /tab: active/
      assert_select ".raa-record-table h3 a[href*='scope=active']"
    end
  end

  def test_metric_card_and_record_table_show_provenance_and_doctor_names_read_surfaces
    Customer.create!(account_id: 1, name: "Bob", points: 40, active: true)
    @customer.update!(points: 10, active: true)
    with_interactive do
      chat = new_chat
      ask_and_run(chat, "Filtered sum and sorted list",
        [ "aggregate_records", { resource: "interactive_customers", function: "sum", field: "points", filters: { points: { gte: 20 } } } ],
        [ "search_records", { resource: "interactive_customers", query: "Bob", sort: "name", direction: "desc" } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-metric-card .raa-metric-value", text: "40"
      assert_select ".raa-metric-card .raa-surface-meta", text: /Points/
      assert_select ".raa-metric-card .raa-surface-meta", text: /Live/
      assert_select ".raa-record-table .raa-surface-meta", text: /sort: name desc/
      assert_select ".raa-record-table h3 a[href*='q=Bob']"

      check = RailsAiAdmin::Doctor.new.surface_check
      assert_includes check.message, "raa_record_card"
      assert_includes check.message, "raa_record_table"
      assert_includes check.message, "raa_metric_card"
    end
  end

  def test_metric_card_recomputes_live_and_denies_after_grant_revocation
    Customer.create!(account_id: 1, name: "Bob", points: 40, active: false)
    @customer.update!(points: 10, active: true)
    with_interactive do
      chat = new_chat
      ask_and_run(chat, "Sum points by active",
        [ "aggregate_records", { resource: "interactive_customers", function: "sum", field: "points", group_by: "active" } ])

      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-metric-card .raa-metric-value", text: "50"
      assert_select ".raa-metric-card svg rect", count: 2
      assert_select ".raa-metric-card table caption", count: 1
      assert_select ".raa-metric-card table tbody tr", count: 2

      # Revoking read grant on points hides the metric card on reload.
      InteractiveSurfacePolicy.hide_points = true
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-metric-card", count: 0
      refute_includes response.body, "raa-metric-value"
    end
  end

  def test_squatted_read_surface_component_is_rejected
    RailsToolViews.reset_registry!
    RailsToolViews.register("raa_record_card", description: "Squatter", version: "1",
      schema: { type: "object", additionalProperties: false, properties: {} }, partial: "rails_ai_admin/surfaces/record_card",
      policy: ->(_access) { true }, actions: {}, expose_to: [])
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Integrations::ToolViews.check_registration! }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Integrations::ToolViews.ensure_registered! }
  end
end
