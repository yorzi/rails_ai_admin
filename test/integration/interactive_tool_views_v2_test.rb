# frozen_string_literal: true

require "test_helper"
require "support/assistant"
require "rails_ai_admin/doctor"

class EditableSurfaceOperation < RailsAiAdmin::Operation
  reversible true
  input do
    integer :points, required: true, nullable: false
    text :note, required: true, max_length: 80
  end

  def preflight(_context, _record, input)
    { points: input.fetch("points"), name: input.fetch("note") }
  end

  def undo_snapshot(_context, record, _input)
    { "points" => record.points, "name" => record.name }
  end

  def perform(context, record, input)
    record.update!(points: input.fetch("points"), name: input.fetch("note"))
    context.outbox.enqueue("customers.reviewed", customer_ref: context.ref(record))
    success(record)
  end

  def verify(_context, record, input)
    [ check_pass("points_verified", "Points are #{record.points}") ] if record.points == input.fetch("points")
  end

  def compensate(_context, record, snapshot)
    record.update!(points: snapshot.fetch("points"), name: snapshot.fetch("name"))
    success(record)
  end
end

class V2CollectionOperation < RailsAiAdmin::Operation
  lease_duration 10
  execution_window 120
  max_duration 2
  input do
    integer :bonus, required: true, nullable: false
  end

  def preflight(_context, record, input)
    { points: record.points + input.fetch("bonus") }
  end

  def perform(_context, record, input)
    record.update!(points: record.points + input.fetch("bonus"))
    success(record)
  end
end

class InteractiveV2CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :v2_customers
  title :name
  fields do
    id :id
    text :name, searchable: :contains, sortable: true
    integer :points, filterable: true, aggregatable: true
    boolean :active, filterable: true
  end
  operation :adjust, handler: "EditableSurfaceOperation", surface: :editable, assistant: true
  operation :plain_adjust, handler: "EditableSurfaceOperation", surface: true
  operation :bulk_bonus, handler: "V2CollectionOperation", scope: :collection
end

class InteractiveV2Policy < AssistantPolicy
  class_attribute :cancel_grant, default: true

  def view_tasks?(context:) = !denied && context.actor.id == 1
  def select_records?(context:, resource:) = !denied && context.actor.id == 1
  def cancel_operation?(context:, resource:, operation:) = !denied && cancel_grant && context.actor.id == 1
  def read_operation_receipt?(context:, resource:, operation:, record:) = !denied && context.actor.id == 1
  def deliver_work?(**) = !denied
  def undo_operation?(context:, resource:, operation:, record: nil) = !denied && context.actor.id == 1

  def assistant?(context:, resource:)
    !denied && exposed && resource.key == :v2_customers
  end

  def allowed?(context:, action:, resource:, record: nil)
    return !denied && context.actor.id == 1 if %i[adjust plain_adjust bulk_bonus].include?(action.to_sym)
    super
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    operation.to_sym == :bulk_bonus ? [ :bonus ] : %i[points note]
  end

  def fields(context:, resource:, action:, record: nil)
    return [] if denied
    case action
    when :read then %i[id name points active]
    when :write then %i[name points active]
    when :search, :sort then [ :name ]
    when :filter then %i[points active]
    else []
    end
  end
end

class InteractiveToolViewsV2Test < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  RESOURCES = %w[InteractiveV2CustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    InteractiveV2Policy.cancel_grant = true
    @second = Customer.create!(account_id: 1, name: "Bob", points: 10)
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
    AssistantPolicy.exposed = true
  end

  def with_v2(&block)
    with_assistant(surfaces: true, resources: RESOURCES, policy: "InteractiveV2Policy", &block)
  end

  def test_all_seven_surface_components_enforce_anti_squatting_and_doctor_reporting
    with_v2 do
      RailsAiAdmin::Integrations::ToolViews.ensure_registered!
      check = RailsAiAdmin::Doctor.new.surface_check
      %w[
        raa_operation_review
        raa_record_card
        raa_record_table
        raa_metric_card
        raa_task_progress
        raa_execution_receipt
        raa_editable_form
      ].each do |key|
        assert_includes check.message, key
      end

      %w[raa_task_progress raa_execution_receipt raa_editable_form].each do |key|
        RailsToolViews.reset_registry!
        RailsToolViews.register(key, description: "Squatter", version: "1",
          schema: { type: "object", additionalProperties: false, properties: {} },
          partial: "rails_ai_admin/surfaces/record_card",
          policy: ->(_access) { true }, actions: {}, expose_to: [])
        assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Integrations::ToolViews.check_registration! }
        assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Integrations::ToolViews.ensure_registered! }
      end
    end
  end

  def test_editable_form_surface_expires_old_intent_on_edit_and_confirms_fresh_digest
    with_v2 do
      ctx = context
      defn = RailsAiAdmin.operation_registry.fetch(InteractiveV2CustomerAdmin, :adjust)
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(
        context: ctx,
        resource: InteractiveV2CustomerAdmin,
        operation: :adjust,
        target_id: @customer.id,
        expected_version: @customer.lock_version,
        input: { "points" => 25, "note" => "Initial draft" },
        origin: :ui
      )
      original_intent_id = proposal.intent.id
      surface = RailsAiAdmin::Integrations::ToolViews.present_editable_form(
        context: ctx,
        resource: InteractiveV2CustomerAdmin,
        definition: defn,
        record: @customer,
        intent_ref: original_intent_id,
        input: RailsAiAdmin::Integrations::ToolViews.wire_input(proposal.values)
      )

      get "/backoffice/assistant/surfaces/#{surface.id}"
      assert_response :success
      assert_includes response.body, "Initial draft"

      # Edit values via update_preview action: zero domain writes, old intent expired, new intent issued!
      post "/backoffice/assistant/surfaces/#{surface.id}/actions", params: {
        action_name: "update_preview",
        base_revision: surface.revision.to_s,
        idempotency_key: SecureRandom.uuid,
        source_component: "raa_editable_form",
        arguments: {
          entries: [
            { name: "points", value: "90" },
            { name: "note", value: "Edited in surface" }
          ]
        }
      }
      assert_response :see_other
      assert_equal 0, @customer.reload.points
      assert_equal "Alice", @customer.name
      old_run = RailsAiAdmin::OperationRun.find(original_intent_id)
      assert_operator old_run.expires_at, :<=, Time.current

      reloaded_surface = RailsToolViews::Surface.find(surface.id)
      new_intent_id = reloaded_surface.state["intent"]
      assert new_intent_id.present?
      refute_equal original_intent_id, new_intent_id

      # Confirming with stale intent ref fails with 409 CONFLICT
      post "/backoffice/assistant/surfaces/#{surface.id}/actions", params: {
        action_name: "confirm",
        base_revision: reloaded_surface.revision.to_s,
        idempotency_key: SecureRandom.uuid,
        source_component: "raa_editable_form",
        arguments: { confirmed_intent: original_intent_id }
      }
      assert_response :conflict
      assert_equal 0, @customer.reload.points

      # Confirming with the fresh shown intent ref commits the edited values!
      reloaded_surface.reload
      post "/backoffice/assistant/surfaces/#{surface.id}/actions", params: {
        action_name: "confirm",
        base_revision: reloaded_surface.revision.to_s,
        idempotency_key: SecureRandom.uuid,
        source_component: "raa_editable_form",
        arguments: { confirmed_intent: new_intent_id }
      }
      assert_response :see_other
      assert_equal 90, @customer.reload.points
      assert_equal "Edited in surface", @customer.name
    end
  end

  def test_task_progress_and_execution_receipt_surfaces_render_live_state_and_verify_badges
    with_v2 do
      ctx = context
      # Execution receipt surface for a verified run with outbox work
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(
        context: ctx,
        resource: InteractiveV2CustomerAdmin,
        operation: :adjust,
        target_id: @customer.id,
        expected_version: @customer.lock_version,
        input: { "points" => 55, "note" => "Receipt check" }
      )
      exec_res = RailsAiAdmin::Operations::Runner.new.execute(
        context: ctx,
        intent_ref: proposal.intent.id,
        input: proposal.values,
        human_confirmed: true
      )
      assert exec_res.success?

      chat = new_chat
      receipt_surface = RailsAiAdmin::Integrations::ToolViews.present_execution_receipt(
        context: ctx,
        run_id: proposal.intent.id,
        chat: chat,
        call_id: "call-receipt-1"
      )
      get "/backoffice/assistant/surfaces/#{receipt_surface.id}"
      assert_response :success
      assert_select ".raa-execution-receipt"
      assert_includes response.body, "points_verified"
      assert_includes response.body, "Pending: 1"

      # Task progress surface for an active bulk collection job, with cancel action
      snap = RailsAiAdmin::Selections::Builder.new.capture(
        context: ctx,
        resource: InteractiveV2CustomerAdmin,
        target_ids: [ @customer.reload.id, @second.id ]
      )
      coll_prop = RailsAiAdmin::Collections::Runner.new.preflight(
        context: ctx,
        resource: InteractiveV2CustomerAdmin,
        operation: :bulk_bonus,
        selection_ref: snap.selection_ref,
        input: { "bonus" => 5 }
      )
      admitted = RailsAiAdmin::Collections::Runner.new.admit(
        context: ctx,
        intent_ref: coll_prop.intent.id,
        input: coll_prop.values,
        human_confirmed: true
      )
      task = RailsAiAdmin::AdminTask.find_by!(operation_run_id: admitted.job_ref)
      progress_surface = RailsAiAdmin::Integrations::ToolViews.present_task_progress(
        context: ctx,
        task_id: task.id,
        chat: chat,
        call_id: "call-progress-1"
      )

      get "/backoffice/assistant/surfaces/#{progress_surface.id}"
      assert_response :success
      assert_select ".raa-task-progress"
      assert_includes response.body, task.title

      post "/backoffice/assistant/surfaces/#{progress_surface.id}/actions", params: {
        action_name: "cancel",
        base_revision: progress_surface.revision.to_s,
        idempotency_key: SecureRandom.uuid,
        source_component: "raa_task_progress",
        arguments: {}
      }
      assert_response :see_other
      assert_equal "cancelled", task.reload.status
    end
  end

  def test_streaming_status_only_poll_executes_zero_domain_surface_queries
    @customer.update!(points: 20, active: true)
    with_v2 do
      chat = new_chat
      get "/backoffice/assistant/conversations/#{chat.ref}"
      key = css_select("input[name='admission_key']").first["value"]
      post "/backoffice/assistant/conversations/#{chat.ref}/messages", params: { content: "Sum points", admission_key: key }
      LLMFixture.tool("aggregate_records", { resource: "v2_customers", function: "sum", field: "points" })
      LLMFixture.tool("search_records", { resource: "v2_customers", query: "Alice" })
      LLMFixture.reply("Total is 30.")
      perform_enqueued_jobs(only: RailsAiAdmin::AssistantTurnJob)

      # Full GET renders MetricCard + RecordTable (executes domain queries)
      get "/backoffice/assistant/conversations/#{chat.ref}"
      assert_response :success
      assert_select ".raa-metric-card"
      assert_select ".raa-record-table"

      # Start a second turn in streaming state
      turn2 = admit(chat, "Explain that")
      turn2.update!(status: "running", lease_owner: "owner-1", generation: 1,
        lease_expires_at: 5.minutes.from_now, draft: "Streaming explanation...")

      customer_queries = []
      listener = lambda do |*_args, payload|
        sql = payload[:sql].to_s
        customer_queries << sql if sql.match?(/FROM\s+["`]?customers["`]?/i)
      end

      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        get "/backoffice/assistant/conversations/#{chat.ref}",
          params: { status_only: "1" },
          headers: { "Turbo-Frame" => "raa_assistant_turn_status" }
      end
      assert_response :success
      assert_select "turbo-frame#raa_assistant_turn_status"
      assert_select "li.raa-chat-streaming[aria-busy=true]", text: /Streaming explanation/
      assert_empty customer_queries, "status_only streaming poll must not re-query domain tables for older surfaces"
    end
  end

  # A native write's receipt names who changed which fields: other actors need
  # the record history grant, not just list access.
  def test_native_execution_receipt_is_for_the_actor_or_history_readers
    with_v2 do
      runner = RailsAiAdmin::Operations::Runner.new
      prop = runner.preflight(context: context, resource: InteractiveV2CustomerAdmin, operation: :update,
        target_id: @second.id, expected_version: @second.lock_version, input: { "points" => 11 })
      assert_equal "OK", runner.execute(context: context, intent_ref: prop.intent.id, input: { "points" => 11 }, human_confirmed: true).code
      other = RailsAiAdmin::Context.new(actor: TestActor.new(2), tenant: TestTenant.new(1), security_version: "1")
      surfaces = RailsAiAdmin::Integrations::ToolViews
      assert surfaces.send(:execution_receipt_authorized?, context, prop.intent.id)
      refute surfaces.send(:execution_receipt_authorized?, other, prop.intent.id)
      InteractiveV2Policy.class_eval { def view_history?(context:, resource:, record:) = true }
      assert surfaces.send(:execution_receipt_authorized?, other, prop.intent.id)
    ensure
      InteractiveV2Policy.class_eval { remove_method :view_history? if method_defined?(:view_history?, false) }
    end
  end

  # surface: :editable presents the editable form from the native review, and a
  # confirmed review of either kind shows the committed receipt.
  def test_opted_in_operations_get_the_editable_form_and_confirmed_reviews_show_the_receipt
    with_v2 do
      { adjust: "raa_editable_form", plain_adjust: "raa_operation_review" }.each do |operation, component|
        @customer.reload
        proposal = RailsAiAdmin::Operations::Runner.new.preflight(context: context, resource: InteractiveV2CustomerAdmin,
          operation: operation, target_id: @customer.id, expected_version: @customer.lock_version,
          input: { "points" => 30, "note" => "Via #{operation}" })
        wire = RailsAiAdmin::Integrations::ToolViews.wire_input(proposal.values).to_json
        post "/backoffice/v2_customers/#{@customer.id}/operations/#{operation}/surface",
          params: { intent_ref: proposal.intent.id, confirmed_input: wire }
        assert_response :see_other
        surface = RailsToolViews::Surface.find(response.location[%r{surfaces/([^/?]+)}, 1])
        assert_equal component, surface.component_key

        arguments = component == "raa_editable_form" ? { confirmed_intent: proposal.intent.id } : {}
        post "/backoffice/assistant/surfaces/#{surface.id}/actions", params: { action_name: "confirm",
          base_revision: surface.revision.to_s, idempotency_key: SecureRandom.uuid, source_component: component, arguments: arguments }
        assert_response :see_other
        get "/backoffice/assistant/surfaces/#{surface.id}"
        assert_select ".raa-execution-receipt", 1
        assert_includes response.body, "points_verified"
        @customer.reload.update!(points: 0)
      end
    end
  end
end
