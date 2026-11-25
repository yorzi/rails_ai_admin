# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# E02 Phase 1 — Per-resource/field semantic metadata, bounded OR filters, and
# single-hop relation (IN subquery) filters with anti-fan-out aggregates.
class SemanticCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :semantic_customers
  title :name
  description "Active and historic customer accounts billed in USD."
  fields do
    id :id
    text :name, searchable: :contains, filterable: [ :eq, :contains ], description: "Customer legal or display name."
    integer :points, filterable: true, aggregatable: true, description: "Loyalty points balance."
    boolean :active, filterable: true
    text :secret, description: "Internal note never granted to read."
  end
  has_many :invoices, resource: :semantic_invoices, via: :customer
end

class SemanticInvoiceAdmin < RailsAiAdmin::Resource
  model "Invoice"
  key :semantic_invoices
  title :number
  description "Customer invoices tracked by billing state."
  fields do
    id :id
    text :number, searchable: :contains, filterable: [ :eq, :contains ], description: "Unique invoice identifier."
    belongs_to :customer, resource: :semantic_customers, filterable: true
  end
end

class SemanticCategoryAdmin < RailsAiAdmin::Resource
  model "Category"
  key :semantic_categories
  title :name
  fields do
    id :id
    text :name, filterable: [ :eq, :contains ]
    belongs_to :parent, resource: :semantic_categories, filterable: true
  end
end

class SemanticQueryPolicy < RailsAiAdmin::Authorization::Adapter
  class_attribute :expose_customers, default: true
  class_attribute :expose_invoices, default: true
  class_attribute :expose_categories, default: true
  class_attribute :allow_customer_name_filter, default: true
  class_attribute :allow_customer_search, default: true
  class_attribute :allow_customer_filters, default: true
  class_attribute :allow_invoice_customer_read, default: true

  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    %i[index show].include?(action.to_sym)
  end

  def assistant?(context:, resource:)
    case resource.key
    when :semantic_customers then expose_customers
    when :semantic_invoices then expose_invoices
    when :semantic_categories then expose_categories
    else false
    end
  end

  def fields(context:, resource:, action:, record: nil)
    case resource.key
    when :semantic_customers
      return [] if action == :filter && !allow_customer_filters
      case action
      when :read then %i[id name points active]
      when :search then allow_customer_search ? [ :name ] : []
      when :filter then allow_customer_name_filter ? %i[name points active] : %i[points active]
      else []
      end
    when :semantic_invoices
      case action
      when :read then allow_invoice_customer_read ? %i[id number customer] : %i[id number]
      when :search then [ :number ]
      when :filter then %i[number customer]
      else []
      end
    when :semantic_categories
      case action
      when :read then %i[id name parent]
      when :filter then %i[name parent]
      else []
      end
    else []
    end
  end
end

class SemanticAndRelationQueriesTest < Minitest::Test
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  RESOURCES = %w[SemanticCustomerAdmin SemanticInvoiceAdmin SemanticCategoryAdmin].freeze

  def setup
    reset_database
    reset_assistant
    SemanticQueryPolicy.expose_customers = true
    SemanticQueryPolicy.expose_invoices = true
    SemanticQueryPolicy.expose_categories = true
    SemanticQueryPolicy.allow_customer_name_filter = true
    SemanticQueryPolicy.allow_invoice_customer_read = true
    @judy = Customer.create!(account_id: 1, name: "Judy Jones", points: 100, active: true)
    @bob = Customer.create!(account_id: 1, name: "Bob Brown", points: 25, active: false)
    @carol = Customer.create!(account_id: 1, name: "Carol White", points: 200, active: false)
    @other_judy = Customer.create!(account_id: 2, name: "Judy Jones", points: 999, active: true)
    @inv1 = Invoice.create!(account_id: 1, customer_id: @judy.id, number: "INV-101")
    @inv2 = Invoice.create!(account_id: 1, customer_id: @judy.id, number: "INV-102")
    @inv3 = Invoice.create!(account_id: 1, customer_id: @bob.id, number: "INV-201")
    @inv_cross = Invoice.create!(account_id: 1, customer_id: @other_judy.id, number: "INV-LEAK")
    @inv_t2 = Invoice.create!(account_id: 2, customer_id: @other_judy.id, number: "INV-T2")
  end

  def teardown
    SemanticQueryPolicy.allow_customer_search = true
    SemanticQueryPolicy.allow_customer_filters = true
    SemanticQueryPolicy.expose_customers = true
    SemanticQueryPolicy.expose_invoices = true
    SemanticQueryPolicy.expose_categories = true
    SemanticQueryPolicy.allow_customer_name_filter = true
    SemanticQueryPolicy.allow_invoice_customer_read = true
  end

  def with_semantic_assistant(&block)
    with_assistant(resources: RESOURCES, policy: "SemanticQueryPolicy", &block)
  end

  def session_for(actor: 1, tenant: 1)
    RailsAiAdmin::Assistant::Session.new(context: context(actor: actor, tenant: tenant), chat: nil, fence: -> { }, conversation: "conv-1")
  end

  def test_semantic_descriptions_validate_freeze_and_never_leak_ungranted_fields
    assert_raises(RailsAiAdmin::ConfigurationError) do
      Class.new(RailsAiAdmin::Resource) { description "" }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      Class.new(RailsAiAdmin::Resource) { description "line1\nline2" }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      Class.new(RailsAiAdmin::Resource) do
        model "Customer"
        key :bad_desc
        title :name
        fields { text :name, description: "x" * 301 }
      end
    end

    with_semantic_assistant do
      listed = RailsAiAdmin::Assistant::ListResources.new(session_for).execute
      customer_entry = listed["resources"].find { |entry| entry["key"] == "semantic_customers" }
      assert_equal "Active and historic customer accounts billed in USD.", customer_entry["description"]

      described = RailsAiAdmin::Assistant::DescribeResource.new(session_for).execute(resource: "semantic_customers")
      assert_equal "Active and historic customer accounts billed in USD.", described["description"]
      name_field = described["fields"].find { |field| field["name"] == "name" }
      assert_equal "Customer legal or display name.", name_field["description"]
      refute described["fields"].any? { |field| field["name"] == "secret" }, "ungranted field and its description stay hidden"
      refute_includes described.to_json, "Internal note never granted"

      relations = described["filter_relations"]
      assert_equal [ "invoices" ], relations.map { |entry| entry["relation"] }
      assert_equal "has_many", relations.first["kind"]
      assert_equal "semantic_invoices", relations.first["resource"]
    end
  end

  def test_bounded_or_filters_work_across_search_count_and_aggregate
    with_semantic_assistant do
      or_groups = [ { "points" => { "gte" => 150 } }, { "active" => { "eq" => true } } ]
      search = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(resource: "semantic_customers", any: or_groups)
      names = search["records"].map { |record| record.dig("fields", "name") }.sort
      assert_equal [ "Alice", "Carol White", "Judy Jones" ], names

      # Combining top-level AND filters with OR groups.
      count = RailsAiAdmin::Assistant::CountRecords.new(session_for).execute(
        resource: "semantic_customers",
        filters: { "points" => { "gte" => 50 } },
        any: or_groups
      )
      assert_equal 2, count["count"]

      total = RailsAiAdmin::Assistant::AggregateRecords.new(session_for).execute(
        resource: "semantic_customers",
        function: "sum",
        field: "points",
        filters: { "points" => { "gte" => 50 } },
        any: or_groups
      )
      assert_equal 300, total["value"]

      # Ungranted field inside OR group fails closed.
      bad = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_customers",
        any: [ { "secret" => { "eq" => "x" } } ]
      )
      assert_equal "INVALID_QUERY", bad["error"]

      # Exceeding MAX_OR_GROUPS fails closed.
      too_many = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_customers",
        any: Array.new(6) { { "active" => { "eq" => true } } }
      )
      assert_equal "INVALID_QUERY", too_many["error"]
    end
  end

  def test_belongs_to_relation_filter_solves_cross_resource_lookup_with_tenant_isolation
    with_semantic_assistant do
      described = RailsAiAdmin::Assistant::DescribeResource.new(session_for).execute(resource: "semantic_invoices")
      rel = described["filter_relations"].find { |entry| entry["relation"] == "customer" }
      assert rel
      assert_equal "belongs_to", rel["kind"]
      assert_includes rel["filters"].map { |entry| entry["field"] }, "name"

      # "List the invoice numbers of Judy Jones" — resolves across belongs_to
      # without leaking tenant-2 Judy Jones's invoice or cross-tenant link!
      search = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_invoices",
        relation_filters: { "customer" => { "name" => { "contains" => "Judy Jones" } } }
      )
      numbers = search["records"].map { |record| record.dig("fields", "number") }.sort
      assert_equal [ "INV-101", "INV-102" ], numbers

      agg = RailsAiAdmin::Assistant::AggregateRecords.new(session_for).execute(
        resource: "semantic_invoices",
        function: "count",
        relation_filters: { "customer" => { "name" => { "contains" => "Judy Jones" } } }
      )
      assert_equal 2, agg["count"]
    end
  end

  def test_has_many_relation_filter_never_multiplies_aggregate_rows
    with_semantic_assistant do
      # Judy Jones has TWO invoices matching INV-10; filtering customers by
      # has_many :invoices must count Judy ONCE and sum points = 100 (NOT 200!).
      agg = RailsAiAdmin::Assistant::AggregateRecords.new(session_for).execute(
        resource: "semantic_customers",
        function: "sum",
        field: "points",
        relation_filters: { "invoices" => { "number" => { "contains" => "INV-10" } } }
      )
      assert_equal 1, agg["count"]
      assert_equal 100, agg["value"]
    end
  end

  def test_self_referential_relation_filter_works_without_table_aliasing_error
    with_semantic_assistant do
      root = Category.create!(account_id: 1, name: "Hardware")
      child = Category.create!(account_id: 1, name: "Laptops", parent_id: root.id)
      Category.create!(account_id: 1, name: "Books")
      search = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_categories",
        relation_filters: { "parent" => { "name" => { "eq" => "Hardware" } } }
      )
      assert_equal [ child.id.to_s ], search["records"].map { |record| record["id"] }
    end
  end

  def test_relation_filters_enforce_assistant_and_target_field_grants
    with_semantic_assistant do
      # 1. Revoking assistant? on target resource omits it and rejects filtering.
      SemanticQueryPolicy.expose_customers = false
      described = RailsAiAdmin::Assistant::DescribeResource.new(session_for).execute(resource: "semantic_invoices")
      assert_nil described["filter_relations"]
      denied = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_invoices",
        relation_filters: { "customer" => { "name" => { "contains" => "Judy" } } }
      )
      assert_equal "INVALID_QUERY", denied["error"]

      # 2. Revoking :filter on target field rejects filtering by that field.
      SemanticQueryPolicy.expose_customers = true
      SemanticQueryPolicy.allow_customer_name_filter = false
      denied = RailsAiAdmin::Assistant::SearchRecords.new(session_for).execute(
        resource: "semantic_invoices",
        relation_filters: { "customer" => { "name" => { "contains" => "Judy" } } }
      )
      assert_equal "INVALID_QUERY", denied["error"]

      # 3. Revoking :read on child back-reference hides the has_many relation filter.
      SemanticQueryPolicy.allow_customer_name_filter = true
      SemanticQueryPolicy.allow_invoice_customer_read = false
      described = RailsAiAdmin::Assistant::DescribeResource.new(session_for).execute(resource: "semantic_customers")
      assert_nil described["filter_relations"]
      denied = RailsAiAdmin::Assistant::CountRecords.new(session_for).execute(
        resource: "semantic_customers",
        relation_filters: { "invoices" => { "number" => { "contains" => "INV-10" } } }
      )
      assert_equal "INVALID_QUERY", denied["error"]
    end
  end

  def test_no_related_record_is_scoped_null_safe_and_correlates_self_references
    with_semantic_assistant do
      optional = Invoice.create!(account_id: 1, number: "NO-CUSTOMER")
      Invoice.create!(account_id: 2, number: "PRIVATE", customer: @carol)
      invoices = RailsAiAdmin::Queries::List.new(context, SemanticInvoiceAdmin, assistant: true)
      relation = invoices.relation(relation_filters: { customer: { _exists: false } })
      assert_match(/NOT\s*\(?EXISTS/i, relation.to_sql)
      assert_equal [ @inv_cross.id, optional.id ].sort, relation.pluck(:id).sort
      count = RailsAiAdmin::Assistant::CountRecords.new(session_for)
      assert_equal 2, count.execute(resource: "semantic_customers", relation_filters: { "invoices" => { "_exists" => false } })["count"]
      assert_equal 3, count.execute(resource: "semantic_customers", relation_filters: { "invoices" => { "_none" => { "number" => { "eq" => "INV-101" } } } })["count"]
      root = Category.create!(account_id: 1, name: "Top")
      Category.create!(account_id: 1, name: "Child", parent: root)
      list = RailsAiAdmin::Queries::List.new(context, SemanticCategoryAdmin)
      assert_equal [ root.id ], list.relation(relation_filters: { parent: { _none: { name: { eq: "Top" } } } }).pluck(:id)
      SemanticQueryPolicy.expose_invoices = false
      assert_equal "INVALID_QUERY", count.execute(resource: "semantic_customers", relation_filters: { "invoices" => { "_exists" => false } })["error"]
    end
  end

  def test_target_search_uses_its_search_grant_and_refuses_ambiguous_negations
    with_semantic_assistant do
      tool = RailsAiAdmin::Assistant::CountRecords.new(session_for)
      search = ->(predicate) { tool.execute(resource: "semantic_invoices", relation_filters: { "customer" => predicate }) }
      SemanticQueryPolicy.allow_customer_name_filter = false
      statements = []
      track = ->(event) { statements << event.payload[:sql] if event.payload[:sql].match?(/\bFROM "(?:invoices|customers)"/i) }
      ActiveSupport::Notifications.subscribed(track, "sql.active_record") do
        assert_equal 2, search.call({ "_query" => "dy Jon" })["count"]
      end
      assert_equal 1, statements.size
      SemanticQueryPolicy.allow_customer_filters = false
      description = RailsAiAdmin::Assistant::DescribeResource.new(session_for).execute(resource: "semantic_invoices")
      relation = description.fetch("filter_relations").sole
      assert relation.fetch("searchable")
      assert_empty relation.fetch("filters")
      assert_equal 2, search.call({ "_query" => "Judy Jones" })["count"]
      assert_equal "INVALID_QUERY", search.call({ "_exists" => false })["error"]
      assert_equal 0, search.call({ "_query" => "%Judy" })["count"]
      [ { "_query" => "" }, { "_exists" => "false" }, { "_none" => {} }, { "_exists" => false, "_query" => "Judy" } ].each do |invalid|
        assert_equal "INVALID_QUERY", search.call(invalid)["error"]
      end
      SemanticQueryPolicy.allow_customer_search = false
      assert_equal "INVALID_QUERY", search.call({ "_query" => "Judy" })["error"]
    end
  end
end
