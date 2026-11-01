# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/operations"
require "rails_ai_admin/integrations/tool_views"

class SurfacesTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers

  def setup
    reset_database
    [ RailsToolViews::AgentInteraction, RailsToolViews::ActionExecution, RailsToolViews::Presentation, RailsToolViews::Surface ].each(&:delete_all)
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def operation_path(action = nil, operation: "review")
    "/backoffice/contract_customers/#{@customer.id}/operations/#{operation}#{action && "/#{action}"}"
  end

  def with_surfaces
    with_operations do
      RailsAiAdmin.configuration.surfaces = true
      yield
    end
  end

  def confirmation(note = "Reviewed in a Surface")
    post operation_path("preflight"), params: { expected_version: @customer.lock_version, input: { note: note } }
    assert_response :success
    { intent_ref: css_select("input[name=intent_ref]").first["value"], confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
  end

  def present(params)
    post operation_path("surface"), params: params
    assert_response :see_other
    surface_id = response.location[%r{/backoffice/assistant/surfaces/([0-9a-f-]{36})\z}, 1]
    assert surface_id, response.location
    surface_id
  end

  def confirm_fields
    css_select("form[action$='/actions'] input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
  end

  def admin_scope(actor: 1)
    RailsAiAdmin::Integrations::ToolViews.scope_for(context(actor: actor))
  end

  def test_native_intent_is_presented_rendered_and_confirmed_once_through_the_admin_endpoint
    with_surfaces do
      proposal = confirmation
      assert_select "button[formaction='#{operation_path("surface")}']", text: "Continue in an interactive review"
      surface_id = present(proposal)
      assert_equal surface_id, present(proposal), "repeat presentation replays the same Surface"
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :success
      assert_select "section.rails-tool-views-surface h2", text: "Review contract operation"
      assert_select "dd", text: "Reviewed in a Surface"
      fields = confirm_fields
      assert_select "form[action='/backoffice/assistant/surfaces/#{surface_id}/actions']"
      assert_select "form[action*='product_surfaces']", count: 0
      assert_equal %w[action_name base_revision idempotency_key source_component], fields.keys.sort
      assert_equal [ "confirm", "1", "raa_operation_review" ], fields.values_at("action_name", "base_revision", "source_component")
      assert_equal "Alice", @customer.reload.name, "presentation and rendering never write"

      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      assert_response :see_other
      follow_redirect!
      assert_select "p[role=status]", text: "Operation completed."
      assert_select "form[action$='/actions']", count: 0
      assert_equal [ "Reviewed in a Surface", 1 ], [ @customer.reload.name, @customer.points ]
      run = RailsAiAdmin::OperationRun.find(proposal[:intent_ref])
      assert_equal [ "succeeded", context.actor_ref ], [ run.status, run.approved_by_ref ]
      assert_equal [ "surface" ], RailsAiAdmin::AuditEvent.where(correlation_ref: run.id, status: "succeeded").pluck(:origin)

      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      assert_response :see_other, "the same idempotency key replays without running the handler"
      post operation_path("execute"), params: proposal
      assert_response :see_other, "the native page replays the committed intent"
      assert_equal 1, RailsAiAdmin::AuditEvent.where(correlation_ref: run.id, status: "succeeded").count
      assert_equal 1, RailsToolViews::ActionExecution.where(surface_id: surface_id).count
      assert_equal 2, RailsToolViews::Surface.find(surface_id).revision
    end
  end

  def test_turbo_stream_actions_replace_only_the_surface_element
    with_surfaces do
      surface_id = present(confirmation)
      get "/backoffice/assistant/surfaces/#{surface_id}"
      dom_id = css_select("section.rails-tool-views-surface").first["id"]
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: confirm_fields, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_includes response.body, %(<turbo-stream action="replace" target="#{dom_id}">)
      assert_includes response.body, "Operation completed."
    end
  end

  def test_native_confirmation_first_makes_the_surface_replay_without_a_second_write
    with_surfaces do
      proposal = confirmation
      surface_id = present(proposal)
      get "/backoffice/assistant/surfaces/#{surface_id}"
      fields = confirm_fields
      post operation_path("execute"), params: proposal
      assert_response :see_other
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      follow_redirect!
      assert_select "p[role=status]", text: "This operation was already completed. No second change was made."
      assert_equal 1, RailsAiAdmin::AuditEvent.where(correlation_ref: proposal[:intent_ref], status: "succeeded").count
      assert_equal [ "ui" ], RailsAiAdmin::AuditEvent.where(correlation_ref: proposal[:intent_ref], status: "succeeded").pluck(:origin)
    end
  end

  def test_stale_revisions_revocation_and_failures_never_write_twice_or_leak
    with_surfaces do
      proposal = confirmation
      surface_id = present(proposal)
      get "/backoffice/assistant/surfaces/#{surface_id}"
      stale = confirm_fields
      OperationJobContext.epoch = "2"
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :success
      assert_select "form[action$='/actions']", count: 0, message: "a revoked security version cannot confirm"
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: stale
      follow_redirect!
      assert_select "p[role=status]", text: /Access or the operation changed/
      assert_equal "Alice", @customer.reload.name
      assert_equal [ "APPROVAL_INVALIDATED" ], RailsAiAdmin::AuditEvent.where(correlation_ref: proposal[:intent_ref]).pluck(:code)
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: stale.merge("idempotency_key" => SecureRandom.uuid)
      assert_response :conflict, "the saved revision moved on"
      assert_select "p[role=alert]"
    end
  end

  def test_operation_failure_rolls_back_the_surface_and_keeps_the_intent_retryable
    with_surfaces do
      proposal = confirmation
      surface_id = present(proposal)
      get "/backoffice/assistant/surfaces/#{surface_id}"
      fields = confirm_fields
      ReviewContractOperation.after_enqueue = ->(_record) { raise "host failure" }
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields
      assert_response :service_unavailable
      assert_includes response.body, "Nothing was changed; try again."
      refute_includes response.body, "host failure"
      assert_equal [ "Alice", 0 ], [ @customer.reload.name, @customer.points ]
      assert_equal [ 1, "proposed" ], [ RailsToolViews::Surface.find(surface_id).revision, RailsAiAdmin::OperationRun.find(proposal[:intent_ref]).status ]
      assert_equal 0, RailsToolViews::ActionExecution.count
      ReviewContractOperation.after_enqueue = nil
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: fields.merge("idempotency_key" => SecureRandom.uuid)
      assert_response :see_other
      assert_equal "Reviewed in a Surface", @customer.reload.name
    end
  end

  def test_foreign_actors_unbound_callers_and_tampered_input_cannot_use_admin_surfaces
    with_surfaces do
      proposal = confirmation
      surface_id = present(proposal)
      post operation_path("surface"), params: proposal.merge(confirmed_input: { note: "Tampered" }.to_json)
      assert_response :conflict, "the intent digest binds the presented input"
      error = assert_raises(RailsToolViews::Error) { RailsToolViews.restore(surface_id, scope: admin_scope) }
      assert_equal "NOT_ALLOWED", error.code, "without a bound admin Context, even the matching scope is denied"
      error = assert_raises(RailsToolViews::Error) do
        RailsToolViews.restore(surface_id, scope: RailsToolViews::Scope.new(actor: "product:TestActor:1", tenant: "product:TestTenant:1"))
      end
      assert_equal "NOT_FOUND", error.code
      RailsAiAdmin::Integrations::ToolViews.with_context(context(actor: 2)) do
        assert_raises(RailsToolViews::Error) { RailsToolViews.restore(surface_id, scope: admin_scope(actor: 1)) }
      end
      post "/test/sign_in/2"
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :not_found
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: { action_name: "confirm", base_revision: "1", idempotency_key: SecureRandom.uuid, source_component: "raa_operation_review" }
      assert_response :not_found
      post "/test/sign_in/1"
      TestPolicy.deny_show = true
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :not_found, "losing current show permission hides the Surface"
      TestPolicy.deny_show = false
      post "/backoffice/assistant/surfaces/#{surface_id}/actions", params: { action_name: "confirm", base_revision: "1", idempotency_key: SecureRandom.uuid, source_component: "raa_operation_review", extra: "x" }
      assert_response :unprocessable_content
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_registration_survives_a_host_registry_reset_and_rejects_squatting
    with_surfaces do
      surface_id = present(confirmation)
      RailsToolViews.reset_registry!
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :success, "the constant contract re-registers with the same digest"
      RailsToolViews.reset_registry!
      RailsToolViews.register("raa_operation_review", description: "Squatter", schema: RailsAiAdmin::Integrations::ToolViews::SCHEMA,
        partial: "rails_ai_admin/surfaces/operation_review", policy: ->(_access) { true }, version: "1")
      get "/backoffice/assistant/surfaces/#{surface_id}"
      assert_response :service_unavailable
    end
  end

  def test_declarations_configuration_and_doctor_report_the_opt_in
    assert ContractCustomerAdmin.surface_operation?(:review)
    refute ContractCustomerAdmin.surface_operation?(:invalid)
    [ { surface: "yes" }, { surface: true, scope: :collection } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError) do
        Class.new(RailsAiAdmin::Resource) { operation :sample, handler: "ReviewContractOperation", **options }
      end
    end
    config = RailsAiAdmin::Configuration.new
    config.surfaces = "on"
    assert_raises(RailsAiAdmin::ConfigurationError) { config.finalize! }
    require "rails_ai_admin/doctor"
    with_surfaces do
      check = RailsAiAdmin::Doctor.new(configuration: RailsAiAdmin.configuration, registry: RailsAiAdmin.registry, application: nil).checks.find { |entry| entry.name == "surfaces" }
      assert_equal :review, check.status
      assert_match(/raa_operation_review is registered for 1 member operations/, check.message)
    end
    closed = RailsAiAdmin::Doctor.new(configuration: RailsAiAdmin::Configuration.new, registry: RailsAiAdmin.registry, application: nil).checks.find { |entry| entry.name == "surfaces" }
    assert_equal :closed, closed.status
  end

  def test_surfaces_stay_closed_unless_the_host_opts_in_and_the_operation_allows_it
    with_operations do
      proposal = confirmation
      assert_select "button[formaction]", count: 0
      post operation_path("surface"), params: proposal
      assert_response :not_found
    end
    with_surfaces do
      post operation_path("preflight", operation: "failing_preview"), params: { expected_version: @customer.lock_version, input: { note: "x" } }
      assert_select "button[formaction]", count: 0
    end
  end
end
