# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

# RAA-0210: CSRF, mass assignment, XSS and N+1 regressions swept across the
# engine's list, record, selection, job, picker, Surface and Chat routes.
class SecurityRegressionsTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  PAYLOAD = %(<script>alert(1)</script>"'><img src=x onerror=alert(2)>)
  RAW_MARKERS = [ "<script>alert(1)", "<img src=x", "onerror=alert(2)>" ].freeze

  class SelectionPolicy < TestPolicy
    def select_records?(context:, resource:) = context.actor.id == 1
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_selection_policy
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "SecurityRegressionsTest::SelectionPolicy"
    RailsAiAdmin.stub(:configuration, config) { yield }
  end

  def with_forgery_protection
    previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
    RailsAiAdmin::ApplicationController.allow_forgery_protection = true
    yield
  ensure
    RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
  end

  def state_snapshot
    [ Customer.order(:id).pluck(:id, :name, :points, :secret, :lock_version), RailsAiAdmin::OperationRun.count,
      RailsAiAdmin::AuditEvent.count, RailsAiAdmin::Selection.count, RailsAiAdmin::WorkItem.count ]
  end

  def sample_path(route)
    values = { resource: "customers", id: @customer.id.to_s, operation: "review", job_ref: SecureRandom.uuid,
      selection_ref: SecureRandom.uuid, surface_id: SecureRandom.uuid, chat_ref: SecureRandom.uuid }
    "/backoffice" + route.path.spec.to_s.sub("(.:format)", "").gsub(/:(\w+)/) { values.fetch(Regexp.last_match(1).to_sym) }
  end

  def assert_escaped(page)
    RAW_MARKERS.each { |marker| refute_includes response.body, marker, "#{page} rendered #{marker.inspect} unescaped" }
  end

  def test_every_state_changing_engine_route_rejects_a_missing_csrf_token_without_side_effects
    routes = RailsAiAdmin::Engine.routes.routes.reject { |route| route.verb.blank? || route.verb.match?(/GET|HEAD/) }
    assert_operator routes.size, :>=, 15, "the sweep must reach the Surface and Chat routes too"
    before = state_snapshot
    with_forgery_protection do
      routes.each do |route|
        path = sample_path(route)
        verb = route.verb[/POST|PATCH|PUT|DELETE/].downcase
        public_send(verb, path, params: { intent_ref: "x", record: { name: "Attack" }, target_ids: [ @customer.id ] })
        assert_response :unprocessable_content, "#{route.verb} #{path} must reject a missing token"
        refute_includes response.body, "Alice", "#{path} leaked a record in its CSRF failure"
      end
    end
    assert_equal before, state_snapshot
  end

  def test_unwritable_and_framework_attributes_are_never_mass_assigned
    get "/backoffice/customers/#{@customer.id}/edit"
    intent = css_select("input[name=intent_ref]").first["value"]
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: intent, record: { name: "Alice B",
      secret: "overwritten", account_id: "2", id: "999", lock_version: "50", created_at: "2000-01-01" } }
    @customer.reload
    assert_equal [ "never show", 1, 0 ], [ @customer.secret, @customer.account_id, @customer.lock_version ]
    refute Customer.exists?(999)

    get "/backoffice/customers/new"
    intent = css_select("input[name=intent_ref]").first["value"]
    assert_no_difference -> { Customer.where(secret: "planted").count } do
      post "/backoffice/customers", params: { intent_ref: intent, record: { name: "Carol", secret: "planted", account_id: "2" } }
    end
    assert_empty Customer.where(account_id: 2, name: "Carol")

    # A read-only actor submits a form it was never offered.
    post "/test/sign_in/2"
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: intent, record: { name: "Mallory" } }
    assert_not_equal "Mallory", @customer.reload.name
  end

  def test_record_text_and_request_values_are_escaped_on_every_page
    @customer.update!(name: PAYLOAD, points: 3)
    with_selection_policy do
      { "index" => [ "/backoffice/customers", {} ],
        "search" => [ "/backoffice/customers", { q: PAYLOAD } ],
        "filter" => [ "/backoffice/customers", { filter: { points: { eq: PAYLOAD } } } ],
        "show" => [ "/backoffice/customers/#{@customer.id}", {} ],
        "edit" => [ "/backoffice/customers/#{@customer.id}/edit", {} ],
        "confirm destroy" => [ "/backoffice/customers/#{@customer.id}/confirm_destroy", {} ],
        "return state" => [ "/backoffice/customers/#{@customer.id}", { return_to: { q: PAYLOAD } } ],
        "overview" => [ "/backoffice", {} ] }.each do |page, (path, params)|
        get path, params: params
        assert_includes [ 200, 303, 422 ], response.status, page
        assert_escaped(page)
      end

      get "/backoffice/customers/references/search", params: { q: "<script" }, headers: { "Accept" => "application/json" }
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]

      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      follow_redirect!
      assert_response :success
      assert_escaped("selection")
    end
  end

  def test_list_and_selection_pages_do_not_query_per_row
    with_selection_policy do
      few = count_selects { get "/backoffice/customers" }
      assert_response :success
      15.times { |index| Customer.create!(account_id: 1, name: "Customer #{index}", points: index) }
      many = count_selects { get "/backoffice/customers" }
      assert_response :success
      assert_equal few, many, "the index must not add a query per row"

      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      one = URI(response.location).path
      post "/backoffice/customers/selections", params: { target_ids: Customer.where(account_id: 1).ids }
      sixteen = URI(response.location).path
      single = count_selects { get one }
      assert_response :success
      multiple = count_selects { get sixteen }
      assert_response :success
      assert_equal single, multiple, "a selection page must not add a query per target"
    end
  end

  private

  def count_selects
    count = 0
    listener = ->(*, payload) { count += 1 if payload[:sql].match?(/\A\s*SELECT/i) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { yield }
    count
  end
end
