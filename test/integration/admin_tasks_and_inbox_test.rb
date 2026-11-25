# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class TaskInboxOperation < RailsAiAdmin::Operation
  approval_mode :separate_actor
  reversible true
  input do
    integer :points, required: true, nullable: false
    text :reason, required: true, max_length: 120
  end

  def preflight(_context, _record, input)
    { points: input.fetch("points") }
  end

  def undo_snapshot(_context, record, _input)
    { "previous_points" => record.points }
  end

  def perform(_context, record, input)
    record.update!(points: input.fetch("points"))
    success(record)
  end

  def verify(_context, record, input)
    [ check_pass("points_applied", "Points updated to #{record.points}") ] if record.points == input.fetch("points")
  end

  def compensate(_context, record, snapshot)
    record.update!(points: snapshot.fetch("previous_points"))
    success(record)
  end
end

class TaskInboxCollectionOperation < RailsAiAdmin::Operation
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

class TaskInboxCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :task_customers
  title :name
  fields do
    id :id
    text :name
    integer :points
  end
  operation :adjust_points, handler: "TaskInboxOperation"
  operation :grant_bonus, handler: "TaskInboxCollectionOperation", scope: :collection
end

class TaskInboxHiddenAdmin < RailsAiAdmin::Resource
  model "Memo"
  key :task_hidden_memos
  title :name
  fields do
    id :id
    text :name
  end
end

class TaskInboxPolicy < RailsAiAdmin::Authorization::Adapter
  def view_tasks?(context:)
    [ 1, 2, 3 ].include?(context.actor.id)
  end

  def scope(context:, resource:, relation:)
    return relation.none if resource == TaskInboxHiddenAdmin && context.actor.id != 3
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    return false if resource == TaskInboxHiddenAdmin && context.actor.id != 3
    [ 1, 2, 3 ].include?(context.actor.id)
  end

  def fields(context:, resource:, action:, record: nil)
    return [] if resource == TaskInboxHiddenAdmin && context.actor.id != 3
    return %i[id name points] if action == :read
    return %i[name points] if action == :write
    []
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    operation.to_sym == :grant_bonus ? [ :bonus ] : %i[points reason]
  end

  def select_records?(context:, resource:) = [ 1, 2 ].include?(context.actor.id)
  def read_operation_receipt?(context:, resource:, operation:, record:) = [ 1, 2 ].include?(context.actor.id)
  def cancel_operation?(context:, resource:, operation:) = [ 1, 2 ].include?(context.actor.id)

  def approve_operation?(context:, resource:, operation:, record: nil, proposed_by_actor_ref: nil)
    context.actor.id == 2
  end

  def undo_operation?(context:, resource:, operation:, record: nil)
    context.actor.id == 2
  end
end

class TaskInboxContextAdapter
  def resolve(controller)
    id = controller.session[:actor_id]
    tenant_id = controller.session[:tenant_id] || 1
    return unless id
    RailsAiAdmin::Context.new(actor: TestActor.new(id), tenant: TestTenant.new(tenant_id), security_version: "1")
  end

  def resolve_job(actor_ref:, tenant_ref:, security_version:)
    actor_id = actor_ref.split(":").last.to_i
    tenant_id = tenant_ref.split(":").last.to_i
    RailsAiAdmin::Context.new(actor: TestActor.new(actor_id), tenant: TestTenant.new(tenant_id), security_version: security_version)
  end
end

class AdminTasksAndInboxTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers
  self.use_transactional_tests = false

  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Bob", points: 5)
  end

  def with_task_inbox(assistant: false, surfaces: false)
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "TaskInboxContextAdapter"
    config.authorization_adapter = "TaskInboxPolicy"
    config.resources = %w[TaskInboxCustomerAdmin TaskInboxHiddenAdmin]
    config.assistant = assistant
    config.surfaces = surfaces
    config.finalize!
    registry = RailsAiAdmin::Registry.new(config.resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def ctx_for(actor_id, tenant_id: 1)
    RailsAiAdmin::Context.new(actor: TestActor.new(actor_id), tenant: TestTenant.new(tenant_id), security_version: "1")
  end

  def test_separate_actor_approval_inbox_workflow_undo_and_no_ai_dependency
    with_task_inbox(assistant: false, surfaces: false) do
      proposer_ctx = ctx_for(1)
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(
        context: proposer_ctx,
        resource: TaskInboxCustomerAdmin,
        operation: :adjust_points,
        target_id: @customer.id,
        expected_version: @customer.lock_version,
        input: { "points" => 75, "reason" => "Loyalty tier adjustment" }
      )
      task = RailsAiAdmin::AdminTask.find_by!(operation_run_id: proposal.intent.id)
      assert_equal "awaiting_approval", task.status
      assert_equal "change_review", task.kind

      # Proposer (actor 1) sees task in "mine", NOT in "needs_approval", and sees NO approve button on show
      proposer_sess = open_session
      proposer_sess.post "/test/sign_in/1"
      proposer_sess.get "/backoffice/tasks", params: { tab: "mine" }
      assert_equal 200, proposer_sess.response.status
      assert_includes proposer_sess.response.body, task.title

      proposer_sess.get "/backoffice/tasks", params: { tab: "needs_approval" }
      refute_includes proposer_sess.response.body, task.id

      proposer_sess.get "/backoffice/tasks/#{task.id}"
      assert_equal 200, proposer_sess.response.status
      refute_includes proposer_sess.response.body, "/backoffice/tasks/#{task.id}/approve"

      # Self-approval POST by proposer is rejected
      proposer_sess.post "/backoffice/tasks/#{task.id}/approve", params: { approval_note: "Trying self-approve" }
      assert_equal 409, proposer_sess.response.status
      assert_equal 0, @customer.reload.points

      # Reviewer (actor 2) sees task in "needs_approval", approves it, and can undo it
      reviewer_sess = open_session
      reviewer_sess.post "/test/sign_in/2"
      reviewer_sess.get "/backoffice/tasks", params: { tab: "needs_approval" }
      assert_equal 200, reviewer_sess.response.status
      assert_includes reviewer_sess.response.body, task.title

      reviewer_sess.get "/backoffice/tasks/#{task.id}"
      assert_equal 200, reviewer_sess.response.status
      assert_includes reviewer_sess.response.body, "/backoffice/tasks/#{task.id}/approve"

      reviewer_sess.post "/backoffice/tasks/#{task.id}/approve", params: { approval_note: "Verified customer tier" }
      assert_equal 303, reviewer_sess.response.status
      assert_equal 75, @customer.reload.points
      assert_equal "succeeded", task.reload.status
      assert_equal "passed", task.summary_metadata["verification_status"]
      assert_operator task.events.count, :>=, 2

      reviewer_sess.get "/backoffice/tasks/#{task.id}"
      assert_equal 200, reviewer_sess.response.status
      assert_includes reviewer_sess.response.body, "points_applied"
      assert_includes reviewer_sess.response.body, "/backoffice/tasks/#{task.id}/undo"

      reviewer_sess.post "/backoffice/tasks/#{task.id}/undo"
      assert_equal 303, reviewer_sess.response.status
      assert_equal 0, @customer.reload.points
      assert task.events.where(event_type: "undone").exists?
    end
  end

  def test_cross_tenant_isolation_expired_approval_and_executing_bulk_task_progress
    with_task_inbox(assistant: false, surfaces: false) do
      proposer_ctx = ctx_for(1, tenant_id: 1)
      proposal = RailsAiAdmin::Operations::Runner.new.preflight(
        context: proposer_ctx,
        resource: TaskInboxCustomerAdmin,
        operation: :adjust_points,
        target_id: @customer.id,
        expected_version: @customer.lock_version,
        input: { "points" => 30, "reason" => "Cross-tenant test" }
      )
      task = RailsAiAdmin::AdminTask.find_by!(operation_run_id: proposal.intent.id)

      # Cross-tenant actor gets 404
      foreign_ctx = ctx_for(2, tenant_id: 2)
      assert_empty RailsAiAdmin::Tasks::Coordinator.list(context: foreign_ctx, tab: "needs_approval")
      assert_raises(RailsAiAdmin::AccessDenied) do
        RailsAiAdmin::Tasks::Coordinator.find_visible!(context: foreign_ctx, id: task.id)
      end

      # Expired approval shows expired and refuses confirmation
      RailsAiAdmin::OperationRun.where(id: proposal.intent.id).update_all(expires_at: 2.minutes.ago)
      task.update!(expires_at: 2.minutes.ago)

      reviewer_sess = open_session
      reviewer_sess.post "/test/sign_in/2"
      reviewer_sess.get "/backoffice/tasks/#{task.id}"
      assert_equal 200, reviewer_sess.response.status
      assert_includes reviewer_sess.response.body.downcase, "expired"

      reviewer_sess.post "/backoffice/tasks/#{task.id}/approve"
      assert_equal 409, reviewer_sess.response.status
      assert_equal 0, @customer.reload.points

      # Async bulk job creates executing task with live progress polling and reaches succeeded
      snap = RailsAiAdmin::Selections::Builder.new.capture(
        context: proposer_ctx,
        resource: TaskInboxCustomerAdmin,
        target_ids: [ @customer.id, @second.id ]
      )
      coll_prop = RailsAiAdmin::Collections::Runner.new.preflight(
        context: proposer_ctx,
        resource: TaskInboxCustomerAdmin,
        operation: :grant_bonus,
        selection_ref: snap.selection_ref,
        input: { "bonus" => 15 }
      )
      admitted = RailsAiAdmin::Collections::Runner.new.admit(
        context: proposer_ctx,
        intent_ref: coll_prop.intent.id,
        input: coll_prop.values,
        human_confirmed: true
      )
      bulk_task = RailsAiAdmin::AdminTask.find_by!(operation_run_id: admitted.job_ref)
      assert_equal "executing", bulk_task.status
      assert_equal "bulk_job", bulk_task.kind

      proposer_sess = open_session
      proposer_sess.post "/test/sign_in/1"
      proposer_sess.get "/backoffice/tasks/#{bulk_task.id}"
      assert_equal 200, proposer_sess.response.status
      assert_includes proposer_sess.response.body, 'data-controller="raa-poll"'

      RailsAiAdmin::Collections::Dispatcher.new.run(admitted.job_ref)
      assert_equal "succeeded", bulk_task.reload.status
      assert_equal 2, bulk_task.summary_metadata["succeeded_count"]
    end
  end
end
