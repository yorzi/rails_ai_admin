# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/assistant"
require "minitest/mock"

class RecipesTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include ContextHelpers
  include AssistantHelpers

  class Adjust < RailsAiAdmin::Operation
    approval_mode :separate_actor
    input { integer :points, required: true }
    def preflight(_context, _record, input) = { points: input.fetch("points") }
    def perform(context, record, input)
      record.update!(points: input.fetch("points"))
      RailsAiAdmin::Recipes.emit("customer.changed", tenant_ref: context.tenant_ref, dedup_key: "recursive")
      success(record)
    end
  end

  class Resource < TestResource
    model "Customer"
    key :recipe_customers
    title :name
    fields do
      id :id
      text :name
      integer :points
    end
    operation :adjust, handler: "RecipesTest::Adjust"
    operation :bulk_adjust, handler: "RecipesTest::Adjust", scope: :collection, approval: :separate_actor
  end

  class Resolver < TestContext
    class_attribute :revoked
    def resolve_job(actor_ref:, tenant_ref:, security_version:)
      return if actor_ref == revoked
      RailsAiAdmin::Context.new(actor: TestActor.new(actor_ref.split(":").last.to_i),
        tenant: TestTenant.new(tenant_ref.split(":").last.to_i), security_version: "1")
    end
  end

  class Policy < TestPolicy
    def assistant?(**) = true
    def run_recipe?(**) = true
    def view_tasks?(**) = true
    def select_records?(**) = true
    def operation_fields(**) = [ :points ]
    def approve_operation?(context:, **) = context.actor.id == 2
    def allowed?(context:, action:, **) = %i[adjust bulk_adjust].include?(action) || super
  end

  def setup
    reset_database
    Resolver.revoked = nil
    @config = RailsAiAdmin::Configuration.new
    @config.context_adapter = "RecipesTest::Resolver"
    @config.authorization_adapter = "RecipesTest::Policy"
    @config.recipe_events = [ "customer.changed" ]
    @config.resources = %w[RecipesTest::Resource]
    @registry = RailsAiAdmin::Registry.new(@config.resources)
  end

  def with_recipes(&block)
    RailsAiAdmin.stub(:configuration, @config) do
      RailsAiAdmin.stub(:registry, @registry) do
        RailsAiAdmin.stub(:operation_registry, RailsAiAdmin::Operations::Registry.new(@registry.resources), &block)
      end
    end
  end

  def install(**opts)
    RailsAiAdmin::Recipes.configure!(**{ owner: context(actor: 3), principal: context, slug: "overdue", name: "Order monitor",
      instructions: "Review the first eligible record.", resource: :recipe_customers,
      plan: { template: "order_monitor", operation: "adjust", input: { points: 9 } }, enabled: true }.merge(opts))
  end

  def fire(key) = RailsAiAdmin::Recipes.trigger!(context: context(actor: 3), slug: "overdue", key: key)
  def execute(run) = RailsAiAdmin::Recipes::Execution.call(run.id)

  def test_manual_review_keeps_domain_writes_behind_separate_approval
    with_recipes do
      recipe = install
      post "/test/sign_in/3"
      get "/backoffice/tasks/recipes/library"
      assert_response :success
      post "/backoffice/tasks/recipes/overdue/run", params: { occurrence: "one" }
      assert_response :see_other
      run = recipe.runs.sole
      execute(run)
      execute(run)
      assert_equal "succeeded", run.reload.status
      assert_equal 0, @customer.reload.points
      task = RailsAiAdmin::AdminTask.sole
      assert_equal [ "recipe_run", 1, run.id ], [ task.kind, task.summary_metadata["recipe_version"], task.summary_metadata["recipe_run_id"] ]
      assert_equal "awaiting_approval", task.status
      post "/test/sign_in/2"
      get "/backoffice/tasks/#{task.id}"
      assert_response :success
      post "/backoffice/tasks/#{task.id}/approve", params: { reviewed_digest: RailsAiAdmin::OperationRun.sole.input_digest }
      assert_response :see_other
      assert_equal 9, @customer.reload.points
      assert_equal "succeeded", task.reload.status
    end
  end

  def test_collection_proposal_binds_the_manifest_and_rechecks_the_principal_before_admission
    with_recipes do
      second = @customer.dup
      second.update!(name: "Second customer")
      install(plan: { template: "order_monitor", operation: "bulk_adjust", input: { points: 8 } })
      run = fire("collection")
      execute(run)
      intent = RailsAiAdmin::OperationRun.sole
      assert_equal [ @customer.id.to_s, second.id.to_s ].sort, intent.manifest_payload.map(&:first).sort
      assert_empty RailsAiAdmin::BatchItem.all
      assert_equal 0, second.reload.points
      post "/test/sign_in/2"
      approve = -> { post "/backoffice/tasks/#{run.reload.task_id}/approve", params: { reviewed_digest: intent.input_digest } }
      Resolver.revoked = context.actor_ref
      approve.call
      assert_response :conflict
      assert_empty RailsAiAdmin::BatchItem.all
      Resolver.revoked = nil
      later = @customer.dup
      later.update!(name: "Later customer")
      approve.call
      assert_response :see_other
      RailsAiAdmin::Collections::Dispatcher.new.run(intent.id, enqueue_continuation: false)
      assert_equal "succeeded", intent.reload.status
      assert_equal [ 8, 8, 0, 0 ], [ @customer, second, later, @other ].map { |record| record.reload.points }
      assert_nil RailsAiAdmin::Recipes::Origin.recipe
    end
  end

  def test_revocations_revisions_and_budget_are_isolated
    with_recipes do
      recipe = install(daily_limit: 1)
      run = fire("first")
      assert_equal run, fire("first")
      assert_equal "skipped_overlap", fire("second").status
      execute(run)
      assert_equal "budget_exceeded", fire("third").status
      Resolver.revoked = context(actor: 3).actor_ref
      task = RailsAiAdmin::AdminTask.sole
      post "/test/sign_in/2"
      post "/backoffice/tasks/#{task.id}/approve", params: { reviewed_digest: RailsAiAdmin::OperationRun.sole.input_digest }
      assert_response :conflict
      assert_equal 0, @customer.reload.points
      recipe = install(daily_limit: 3, instructions: "New instructions")
      assert_equal 2, recipe.version
      run = fire("fourth")
      execute(run)
      assert_equal "paused_revoked", run.reload.status
      refute recipe.reload.enabled?
      assert_equal 2, run.recipe_version
    end
  end

  def test_queue_one_and_event_replay_do_not_widen_the_target
    with_recipes do
      recipe = install(trigger: "event", event: "customer.changed", overlap: "queue_one")
      emit = ->(key, id) { RailsAiAdmin::Recipes.emit("customer.changed", tenant_ref: context.tenant_ref, dedup_key: key, payload: { record_id: id }).sole }
      a = emit.call("a", @customer.id)
      assert_equal a, emit.call("a", @customer.id)
      assert_raises(RailsAiAdmin::AccessDenied) { emit.call("a", @other.id) }
      b = emit.call("b", @other.id)
      assert_equal "skipped_overlap", emit.call("c", @customer.id).status
      execute(b)
      assert_equal "queued", b.reload.status
      execute(a)
      execute(b)
      assert_equal 1, RailsAiAdmin::OperationRun.count
      assert_equal 0, @other.reload.points
      post "/test/sign_in/2"
      post "/backoffice/tasks/#{a.reload.task_id}/approve", params: { reviewed_digest: RailsAiAdmin::OperationRun.sole.input_digest }
      assert_response :see_other
      assert_equal 3, recipe.runs.count
    end
  end

  def test_provider_decision_and_budget_belong_to_recipe_runs
    reset_assistant
    @config.assistant = true
    @config.assistant_adapter = "TestAssistant"
    @config.assistant_provider = "openai"
    @config.assistant_protocol = "chat_completions"
    @config.assistant_model = "gpt-4.1-mini"
    @config.recipe_daily_token_limit = 10
    with_recipes do
      install(plan: { template: "order_monitor", consult_model: true, operation: "adjust", input: { points: 4 } })
      LLMFixture.reply({ review: false }.to_json)
      run = fire("model")
      execute(run)
      assert_equal "succeeded", run.reload.status
      assert_empty RailsAiAdmin::OperationRun.all
      assert_equal 1, RubyLLM::ActiveRecord::Usage.where(owner: run).count
      second = fire("model-2")
      execute(second)
      assert_equal "budget_exceeded", second.reload.status
      assert_equal 1, LLMFixture.requests.size
      assert_equal 0, RailsAiAdmin::Assistant::Budget.spend(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref).tokens
    end
  end

  def test_scan_coalesces_due_occurrences_and_handles_both_dst_transitions
    with_recipes do
      travel_to(Time.utc(2026, 10, 31, 12)) do
        recipe = install(trigger: "schedule", cron: "30 1 * * *", time_zone: "America/New_York")
        first = Time.utc(2026, 11, 1, 5, 30)
        assert_equal first, recipe.next_run_at
        RailsAiAdmin::Recipes.scan(now: first)
        RailsAiAdmin::Recipes.scan(now: first + 1.hour)
        assert_equal 1, recipe.runs.count
        assert_equal Time.utc(2026, 11, 2, 6, 30), recipe.reload.next_run_at
        recipe.schedule_cron = "30 2 * * *"
        assert_equal Time.utc(2026, 3, 9, 6, 30), recipe.next_occurrence(after: Time.utc(2026, 3, 7, 7, 30))
      end
    end
  end
end
