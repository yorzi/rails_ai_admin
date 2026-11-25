# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "support/application"
require "rails_ai_admin/assistant"

class DataQualityRulesTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers
  self.use_transactional_tests = false

  class DuplicateNames < RailsAiAdmin::QualityRule
    key :duplicate_names
    resource :customers
    description "Duplicate customer names"
    remediation_change :update

    def detect(context, relation)
      RailsAiAdmin::Quality::Checks.duplicates_by(relation, columns: [ :name ], normalizer: :lower_trim)
    end
  end

  class Policy < TestPolicy
    def allowed?(context:, action:, resource:, record: nil)
      return false if action == :show && record.is_a?(Customer) && record.points == -1
      super
    end

    def assistant?(context:, resource:) = context.actor.id == 1
    def run_quality_rule?(context:, resource:, rule:) = context.actor.id == 1

    def fields(context:, resource:, action:, record: nil)
      return %i[label kind amount] if resource == Orders && action == :read
      super
    end
  end

  class Orders < RailsAiAdmin::Resource
    model "FilterSample"
    key :orders
    title :label
    fields do
      text :label
      text :kind
      decimal :amount
    end
  end

  class MissingPayment < RailsAiAdmin::QualityRule
    resource :orders
    key :missing_payment
    description "Paid orders without a matching settlement"

    def detect(context, relation)
      orders = relation.klass.arel_table
      payments = Payment.arel_table
      settled = Payment.where(account_id: context.tenant.id).where.not(paid_at: nil)
        .where(payments[:reference].eq(orders[:label])).where(payments[:amount].eq(orders[:amount]))
      relation.where(kind: "paid").where(settled.arel.exists.not).order(:id).limit(self.class.max_findings).pluck(:id).map do |id|
        RailsAiAdmin::Quality::Finding.new(id.to_s, [ id ], "Missing matching payment", %i[label kind amount])
      end
    end
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_rules(*rules, resources: [ TestResource ])
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "TestContext"
    config.authorization_adapter = Policy.name
    config.resources = resources.map(&:name)
    config.quality_rules = (rules.empty? ? [ DuplicateNames ] : rules).map(&:name)
    config.finalize!
    registered = RailsAiAdmin::Registry.new(config.resources)
    registry = RailsAiAdmin::Quality::Registry.new(config.quality_rules, registered)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registered) { RailsAiAdmin.stub(:quality_registry, registry) { yield } }
    end
  end

  def test_custom_check_reconciles_paid_orders_against_tenant_settlements
    with_rules(MissingPayment, resources: [ Orders ]) do
      settled, mismatched, missing = %w[settled mismatched missing].map do |label|
        FilterSample.create!(account_id: 1, label: label, kind: "paid", amount: 20)
      end
      FilterSample.create!(account_id: 1, label: "draft", kind: "draft", amount: 20)
      FilterSample.create!(account_id: 2, label: "private", kind: "paid", amount: 20)
      Payment.create!(account_id: 1, reference: settled.label, amount: 20, paid_at: Time.current)
      Payment.create!(account_id: 1, reference: mismatched.label, amount: 10, paid_at: Time.current)
      Payment.create!(account_id: 2, reference: missing.label, amount: 20, paid_at: Time.current)
      get "/backoffice/orders/quality/rules/missing_payment"
      assert_response :success
      assert_equal [ mismatched.id, missing.id ].map { |id| "/backoffice/orders/#{id}" }, css_select("tbody th a").map { |link| link["href"] }
    end
  end

  def test_resource_list_leads_to_read_only_review_and_correction
    with_rules do
      duplicate = Customer.create!(account_id: 1, name: "ALICE")
      @other.update!(name: "Alice")
      get "/backoffice/customers"
      assert_select "a[href='/backoffice/customers/quality/rules']", text: "Data quality"
      get "/backoffice/customers/quality/rules"
      assert_select "a[href*='duplicate_names']"
      assert_no_difference [ "RailsAiAdmin::OperationRun.count", "RailsAiAdmin::AuditEvent.count" ] do
        get "/backoffice/customers/quality/rules/duplicate_names"
        assert_response :success
      end
      [ duplicate, @customer ].each { |record| assert_select "a[href='/backoffice/customers/#{record.id}/edit']" }
      assert_select "a[href='/backoffice/customers/#{@other.id}']", count: 0
      refute_includes response.body, @customer.secret
      get "/backoffice/customers/#{duplicate.id}/edit"
      assert_response :success
      intent = css_select("input[name=intent_ref]").first["value"]
      assert_difference "RailsAiAdmin::AuditEvent.count", 1 do
        patch "/backoffice/customers/#{duplicate.id}", params: { intent_ref: intent, record: { name: "New name" } }
        assert_response :see_other
      end
      assert_equal "New name", duplicate.reload.name
      get "/backoffice/customers/quality/rules/duplicate_names"
      assert_select "p", text: "No visible findings in this check."
    end
  end

  class BlankPoints < RailsAiAdmin::QualityRule
    key :blank_points
    resource :customers
    description "Customers missing a points balance"
    max_findings 1

    def detect(_context, relation)
      RailsAiAdmin::Quality::Checks.blank_fields(relation, fields: [ :points ])
    end
  end

  class WritingRule < RailsAiAdmin::QualityRule
    key :invalid_detector
    resource :customers
    description "Faulty detector"

    def detect(_context, relation)
      Enumerator.new { |results| results << relation.update_all(points: 999) }
    end
  end

  def test_blank_findings_are_scoped_ordered_and_bounded
    with_rules(BlankPoints) do
      @other.update!(points: nil)
      first, second = 2.times.map { Customer.create!(name: "Blank", points: nil, account_id: 1) }
      get "/backoffice/customers/quality/rules/blank_points"
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "tbody a[href='/backoffice/customers/#{first.id}']"
      [ @other, second, @customer ].each { |record| assert_select "tbody a[href='/backoffice/customers/#{record.id}']", count: 0 }
    end
  end

  def test_detector_and_lazy_iteration_run_under_the_write_guard
    with_rules(WritingRule) do
      get "/backoffice/customers/quality/rules/invalid_detector"
      assert_response :service_unavailable
      assert_equal 0, @customer.reload.points
      assert_equal 0, RailsAiAdmin::AuditEvent.count
    end
  end

  def test_assistant_discovery_and_execution_recheck_current_grants
    with_rules do
      assistant = RailsAiAdmin::Assistant
      session = assistant::Session.new(context: context, chat: nil, fence: -> { })
      duplicate = Customer.create!(account_id: 1, name: @customer.name)
      tools = assistant.tools_for(session).index_by(&:name)
      assert_equal [ "duplicate_names" ], tools.fetch("list_quality_rules").execute(resource: "customers").fetch("rules").pluck("key")
      run = tools.fetch("run_quality_rule")
      check = -> { run.execute(resource: "customers", rule: "duplicate_names") }
      rows = check.call.fetch("findings").sole.fetch("records")
      assert_equal [ @customer.id.to_s, duplicate.id.to_s ], rows.pluck("id")
      assert_equal({ "name" => @customer.name }, rows.first.fetch("evidence"))
      TestPolicy.hide_name = true
      assert_empty check.call.fetch("findings")
      TestPolicy.denied = true
      assert_equal "NOT_FOUND", check.call.fetch("error")
      refute_includes assistant.tools_for(session).map(&:name), "run_quality_rule"
    end
  end

  def test_registry_refuses_unknown_remediation_duplicate_keys_and_unregistered_resources
    registry = RailsAiAdmin::Quality::Registry
    assert_raises(RailsAiAdmin::ConfigurationError) { registry.new([ DuplicateNames.name ] * 2, RailsAiAdmin.registry) }
    assert_raises(RailsAiAdmin::ConfigurationError) { registry.new([ DuplicateNames.name ], RailsAiAdmin::Registry.new([])) }
    DuplicateNames.stub(:remediation_operation, :absent) do
      assert_raises(RailsAiAdmin::ConfigurationError) { registry.new([ DuplicateNames.name ], RailsAiAdmin.registry) }
    end
    assert_equal false, RailsAiAdmin::Authorization::Adapter.new.run_quality_rule?(context: context, resource: TestResource, rule: :duplicate_names)
  end

  def test_withholds_duplicate_group_with_one_unshowable_record
    with_rules do
      Customer.create!(account_id: 1, name: @customer.name, points: -1)
      get "/backoffice/customers/quality/rules/duplicate_names"
      assert_response :success
      assert_select "tbody tr", count: 0
      refute_includes response.body, @customer.name
    end
  end

  def test_assistant_truncates_large_checks_without_losing_the_first_finding
    with_rules do
      # A UTF-8 value can occupy substantially more bytes than characters.
      20.times { Customer.create!(account_id: 1, name: "字" * 300) }
      assistant = RailsAiAdmin::Assistant
      session = assistant::Session.new(context: context, chat: nil, fence: -> { })
      result = assistant::RunQualityRule.new(session).execute(resource: "customers", rule: "duplicate_names")
      assert result.fetch("truncated")
      assert_predicate result.fetch("findings").first.fetch("records"), :any?
      assert_operator JSON.generate(result).bytesize, :<=, assistant::Tool::MAX_RESULT_BYTES
    end
  end

  def test_current_rule_show_and_field_grants
    with_rules do
      Customer.create!(account_id: 1, name: @customer.name)
      TestPolicy.hide_name = true
      get "/backoffice/customers/quality/rules/duplicate_names"
      refute_includes response.body, @customer.name
      TestPolicy.deny_show = true
      get "/backoffice/customers/quality/rules/duplicate_names"
      assert_select "p", text: "No visible findings in this check."
      post "/test/sign_in/2"
      get "/backoffice/customers/quality/rules/duplicate_names"
      assert_response :not_found
      get "/backoffice/customers"
      assert_select "a[href='/backoffice/customers/quality/rules']", count: 0
    end
  end
end
