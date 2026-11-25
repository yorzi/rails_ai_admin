# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "support/application"
require "support/assistant"

class QualityMergeTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers
  self.use_transactional_tests = false

  class Combine < RailsAiAdmin::Quality::MergeOperation
    def merge(_context, target, sources)
      target.update!(points: target.points + sources.sum(&:points))
      sources.each(&:destroy!)
      success(target)
    end

    def verify(_context, record, _input)
      [ check_pass(:balance, record.points.to_s) ]
    end
  end

  class Customers < RailsAiAdmin::Resource
    model "Customer"
    key :merge_customers
    title :name
    fields do
      text :name
      integer :points
    end
    has_many :invoices, resource: :merge_invoices, via: :customer
    operation :merge_customers, handler: "QualityMergeTest::Combine"
  end

  class Duplicates < RailsAiAdmin::QualityRule
    key :duplicates
    resource :merge_customers
    description "Duplicate customer names"
    remediation_operation :merge_customers

    def detect(_context, relation)
      RailsAiAdmin::Quality::Checks.duplicates_by(relation, columns: [ :name ])
    end
  end

  class Invoices < RailsAiAdmin::Resource
    model "Invoice"
    key :merge_invoices
    title :number
    fields do
      text :number
      belongs_to :customer, resource: :merge_customers
    end
  end

  class BrokenReferences < RailsAiAdmin::QualityRule
    key :broken_reference
    resource :merge_invoices
    description "Invoices with an unavailable customer"
    def detect(_context, relation) = orphaned_belongs_to(relation, field: :customer)
  end

  class Categories < RailsAiAdmin::Resource
    model "Category"
    key :categories
    title :name
    fields do
      text :name
      belongs_to :parent, resource: :categories
    end
  end

  class MissingParent < RailsAiAdmin::QualityRule
    key :missing_parent
    resource :categories
    description "Unavailable parent category"
    def detect(_context, relation) = orphaned_belongs_to(relation, field: :parent)
  end

  class Policy < TestPolicy
    class_attribute :hidden_id, default: nil

    def allowed?(context:, action:, resource:, record: nil)
      return false if record && hidden_id == record.id && resource == Customers
      return true if action == :merge_customers && [ 1, 2 ].include?(context.actor.id)
      super
    end

    def fields(context:, resource:, action:, record: nil)
      return %i[name parent] if resource == Categories && action == :read
      if resource == Invoices && action == :read
        return [ :number ] if record&.number == "PRIVATE"
        return %i[number customer]
      end
      super
    end

    def assistant?(context:, resource:) = true
    def approve_operation?(context:, resource:, operation:, record:, proposed_by_actor_ref:) = context.actor.id == 2
    def view_tasks?(context:) = true
    def run_quality_rule?(context:, resource:, rule:) = true
    def operation_fields(context:, resource:, operation:, record: nil) = [ :merge_review ]
    def read_operation_receipt?(context:, resource:, operation:, record:) = true
  end

  def setup
    reset_database
    Policy.hidden_id = nil
    post "/test/sign_in/1"
    @duplicate = Customer.create!(name: @customer.name, account_id: 1, points: 7)
  end

  def test_review_confirm_verify_and_repeat
    with_merge_rules do
      get "/backoffice/merge_customers/quality/rules/duplicates"
      assert_response :success
      link = css_select("a").find { |entry| entry.text == "Keep this record" }
      assert link, "the finding offers a choice of surviving record"
      get link["href"]
      assert_response :success
      assert_select "caption", text: "Compare records"
      assert_select "th", text: "Points"
      form = css_select("form[action$='/preflight']").sole
      post form["action"], params: { expected_version: @customer.lock_version,
        input: { merge_review: form.at_css("input[name='input[merge_review]']")["value"] } }
      assert_response :success
      assert_equal 2, Customer.where(account_id: 1).count
      form = css_select("form[action$='/execute']").sole
      params = form.css("input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }
      2.times do
        post form["action"], params: params
        assert_response :see_other
      end
      assert_equal 7, @customer.reload.points
      refute Customer.exists?(@duplicate.id)
      assert_equal 1, RailsAiAdmin::AuditEvent.where(operation: "merge_customers", status: "succeeded").count
      assert_equal "passed", RailsAiAdmin::OperationRun.find(params["intent_ref"]).verification_status
      get "/backoffice/merge_customers/quality/rules/duplicates"
      assert_select "p", text: "No visible findings in this check."
    end
  end

  def test_stale_source_and_revoked_source_grant_refuse_every_write
    with_merge_rules do
      runner = RailsAiAdmin::Operations::Runner.new
      access = RailsAiAdmin::Authorization::Access.new(context, Customers)
      group = RailsAiAdmin::Quality::Runner.new(access).call(:duplicates).reviews.sole
      prepare = lambda do
        comparison = RailsAiAdmin::Quality::MergeReview.compare(access, :duplicates, group.key, @customer.id.to_s)
        runner.preflight(context: context, resource: Customers, operation: :merge_customers, target_id: @customer.id,
          expected_version: @customer.lock_version, input: { "merge_review" => comparison.token })
      end
      proposal = prepare.call
      @duplicate.update!(points: 9)
      result = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
      assert_equal "CONFLICT", result.code
      proposal = prepare.call
      Policy.hidden_id = @duplicate.id
      result = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
      assert_equal "NOT_FOUND", result.code
      assert_equal [ 0, 9 ], [ @customer.reload.points, @duplicate.reload.points ]
    end
  end

  def test_reference_check_and_association_counts_obey_both_resource_policies
    with_merge_rules do
      Invoice.create!(account_id: 1, number: "PUBLIC", customer: @customer)
      Invoice.create!(account_id: 1, number: "PRIVATE", customer: @customer)
      foreign = Invoice.create!(account_id: 1, number: "HIDDEN-TARGET", customer: @other)
      Invoice.create!(account_id: 1, number: "OPTIONAL")
      Invoice.create!(account_id: 2, number: "OTHER", customer: @customer)
      get "/backoffice/merge_invoices/quality/rules/broken_reference"
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "a[href='/backoffice/merge_invoices/#{foreign.id}']"
      refute_includes response.body, @other.name
      get "/backoffice/merge_customers/quality/rules/duplicates"
      get css_select("a").find { |entry| entry.text == "Keep this record" }["href"]
      assert_select "th", text: /Invoices \(visible/
      assert_equal "1", css_select("tbody tr").first.css("td").last.text
    end
  end

  def test_separate_approver_sees_the_comparison_and_executes_the_same_manifest
    Combine.stub(:approval_mode, :separate_actor) do
      with_merge_rules do
        access = RailsAiAdmin::Authorization::Access.new(context, Customers)
        group = RailsAiAdmin::Quality::Runner.new(access).call(:duplicates).reviews.sole
        comparison = RailsAiAdmin::Quality::MergeReview.compare(access, :duplicates, group.key, @customer.id.to_s)
        proposal = RailsAiAdmin::Operations::Runner.new.preflight(context: context, resource: Customers, operation: :merge_customers,
          target_id: @customer.id, expected_version: @customer.lock_version, input: { "merge_review" => comparison.token })
        task = RailsAiAdmin::AdminTask.find_by!(operation_run_id: proposal.intent.id)
        post "/test/sign_in/2"
        get "/backoffice/tasks/#{task.id}"
        assert_response :success
        assert_select "caption", text: "Compare records"
        refute_includes response.body, comparison.token
        post "/backoffice/tasks/#{task.id}/approve", params: { reviewed_digest: proposal.intent.input_digest }
        assert_response :see_other
        assert_equal context(actor: 2).actor_ref, proposal.intent.reload.approved_by_ref
        refute Customer.exists?(@duplicate.id)
      end
    end
  end

  def test_dangling_self_reference_excludes_roots_and_valid_children
    with_merge_rules do
      root = Category.create!(account_id: 1, name: "Root")
      Category.create!(account_id: 1, name: "Child", parent: root)
      orphan = Category.create!(account_id: 1, name: "Orphan", parent_id: root.id + 100_000)
      get "/backoffice/categories/quality/rules/missing_parent"
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "a[href='/backoffice/categories/#{orphan.id}']"
    end
  end

  def test_chat_tool_presents_a_live_read_only_merge_surface
    with_merge_rules(surfaces: true) do
      assistant = RailsAiAdmin::Assistant
      chat = assistant.create_chat!(context)
      session = assistant::Session.new(context: context, chat: chat, fence: -> { })
      result = assistant::RunQualityRule.new(session).execute(tool_call: Struct.new(:id).new(SecureRandom.uuid),
        resource: "merge_customers", rule: "duplicates")
      get "/backoffice/assistant/surfaces/#{result.fetch("surface")}"
      assert_response :success
      assert_select "caption", text: "Compare records"
      assert_select "a", text: "Review keeping record ##{@customer.id}"
      Policy.hidden_id = @duplicate.id
      get "/backoffice/assistant/surfaces/#{result.fetch("surface")}"
      assert_response :not_found
    end
  end

  private

  def with_merge_rules(surfaces: false)
    config = RailsAiAdmin::Configuration.new
    config.surfaces = config.assistant = surfaces
    config.assistant_model = "gpt-4.1-mini" if surfaces
    config.assistant_adapter = "TestAssistant" if surfaces
    config.context_adapter = "TestContext"
    config.authorization_adapter = Policy.name
    config.resources = [ Customers.name, Invoices.name, Categories.name ]
    config.quality_rules = [ Duplicates.name, BrokenReferences.name, MissingParent.name ]
    registry = RailsAiAdmin::Registry.new(config.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:quality_registry, RailsAiAdmin::Quality::Registry.new(config.quality_rules, registry)) do
          RailsAiAdmin.stub(:operation_registry, RailsAiAdmin::Operations::Registry.new(registry.resources)) { yield }
        end
      end
    end
  end
end
