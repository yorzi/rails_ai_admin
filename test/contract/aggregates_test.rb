# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# Queries::List#aggregate and the assistant's aggregate_records tool.
class AggregatesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers

  class SampleAdmin < RailsAiAdmin::Resource
    model "FilterSample"
    key :agg_samples
    title :label
    fields do
      id :id
      text :label, filterable: [ :eq ]
      enum :kind, values: %w[standard priority rush], filterable: %i[eq in]
      decimal :amount, aggregatable: true, filterable: %i[gte lte]
      date :due_on, aggregatable: true, filterable: %i[gte lte]
      datetime :seen_at, aggregatable: true, filterable: %i[gte lte]
      boolean :flagged, filterable: true
      integer :account_id, aggregatable: true, readonly: true
    end
    scopes do
      scope :flagged, -> { where(flagged: true) }, label: "Flagged"
    end
  end

  class CustomerAdmin < RailsAiAdmin::Resource
    model "Customer"
    key :agg_customers
    title :name
    fields do
      id :id
      text :name
      integer :points, aggregatable: true
      boolean :active, filterable: true
    end
  end

  class InvoiceAdmin < RailsAiAdmin::Resource
    model "Invoice"
    key :agg_invoices
    title :number
    fields do
      id :id
      text :number
      belongs_to :customer, resource: :agg_customers, filterable: true
    end
  end

  RESOURCES = %w[AggregatesTest::SampleAdmin AggregatesTest::CustomerAdmin AggregatesTest::InvoiceAdmin].freeze

  class Policy < RailsAiAdmin::Authorization::Adapter
    class_attribute :read, default: {}
    class_attribute :filter, default: {}
    class_attribute :join_invoices, default: false
    class_attribute :hidden_customers, default: false

    def scope(context:, resource:, relation:)
      scoped = relation.where(account_id: context.tenant.id)
      # A one-to-many join in a policy scope repeats customer rows.
      scoped = scoped.joins("INNER JOIN invoices ON invoices.customer_id = customers.id") if join_invoices && resource.key == :agg_customers
      scoped
    end

    def allowed?(context:, action:, resource:, record: nil)
      return false if hidden_customers && resource.key == :agg_customers
      %i[index show].include?(action.to_sym)
    end

    def assistant?(context:, resource:) = true
    def named_scopes(context:, resource:) = %i[flagged]
    def fields(context:, resource:, action:, record: nil) = { read: read, filter: filter }.fetch(action, {}).fetch(resource.key, [])
  end

  def setup
    reset_database
    reset_assistant
    Policy.read = { agg_samples: %i[id label kind amount due_on seen_at flagged], agg_customers: %i[id name points active], agg_invoices: %i[id number customer] }
    Policy.filter = { agg_samples: %i[label kind amount flagged], agg_customers: %i[active], agg_invoices: %i[customer] }
    Policy.join_invoices = false
    Policy.hidden_customers = false
    sample("A", kind: "standard", amount: "10.25", due_on: "2026-11-01", seen_at: "2026-11-01T09:00:00Z", flagged: true)
    sample("B", kind: "standard", amount: "4.50", due_on: "2026-11-20", flagged: false)
    sample("C", kind: "priority", amount: "100.00", due_on: "2026-10-05", seen_at: "2026-11-03T18:30:00Z", flagged: true)
    sample("D", kind: "rush", amount: nil, flagged: false)
    sample("Foreign", account_id: 2, kind: "rush", amount: "999.99", due_on: "2020-01-01")
  end

  def sample(label, account_id: 1, **attributes) = FilterSample.create!(account_id: account_id, label: label, **attributes)

  def aggregate(resource: SampleAdmin, **options)
    RailsAiAdmin::Queries::List.new(context, resource).aggregate(**options)
  end

  def with_resources(&block) = with_assistant(resources: RESOURCES, policy: "AggregatesTest::Policy", &block)

  def assert_invalid(**options)
    error = assert_raises(RailsAiAdmin::AccessDenied) { aggregate(**options) }
    assert_equal "INVALID_QUERY", error.code
  end

  def test_totals_extremes_and_counts_cover_the_policy_relation_with_filters_and_scope
    with_resources do
      sum = aggregate(function: "sum", field: "amount")
      assert_equal [ 4, BigDecimal("114.75") ], [ sum.count, sum.value ]
      assert_equal BigDecimal("38.25"), aggregate(function: "average", field: "amount").value.round(2), "an empty amount is not averaged"
      assert_equal Date.new(2026, 10, 5), aggregate(function: "minimum", field: "due_on").value
      assert_equal Time.utc(2026, 11, 3, 18, 30), aggregate(function: "maximum", field: "seen_at").value
      assert_equal 4, aggregate(function: "count").count
      assert_equal BigDecimal("110.25"), aggregate(function: "sum", field: "amount", scope: "flagged").value
      filtered = aggregate(function: "sum", field: "amount", filters: { "kind" => { "in" => %w[standard] }, "amount" => { "gte" => "5" } })
      assert_equal [ 1, BigDecimal("10.25") ], [ filtered.count, filtered.value ]
      assert_equal [ 1, BigDecimal("100") ], [ aggregate(function: "sum", field: "amount", search: nil, filters: { "label" => { "eq" => "C" } }).count, BigDecimal("100") ]
      none = aggregate(function: "sum", field: "amount", filters: { "label" => { "eq" => "Missing" } })
      assert_equal [ 0, nil ], [ none.count, none.value ]
    end
  end

  def test_groups_follow_count_order_and_include_empty_values
    with_resources do
      result = aggregate(function: "sum", field: "amount", group_by: "kind")
      assert_equal [ [ "standard", 2, BigDecimal("14.75") ], [ "priority", 1, BigDecimal("100") ], [ "rush", 1, nil ] ],
        result.groups.map { |group| [ group.key, group.count, group.value ] }
      refute result.groups_truncated
      flagged = aggregate(function: "count", group_by: "flagged").groups.map { |group| [ group.key, group.count ] }.sort_by { |key, _| key.to_s }
      assert_equal [ [ false, 2 ], [ true, 2 ] ], flagged
    end
  end

  def test_groups_are_bounded
    with_resources do
      30.times { |index| Customer.create!(account_id: 1, name: "C#{index}").then { |customer| Invoice.create!(account_id: 1, number: "N#{index}", customer: customer) } }
      result = aggregate(resource: InvoiceAdmin, function: "count", group_by: "customer")
      assert_equal 25, result.groups.size
      assert result.groups_truncated
      assert_equal 30, result.count
    end
  end

  def zoned(time_zone, **options)
    zone = RailsAiAdmin::Context.new(actor: TestActor.new(1), tenant: TestTenant.new(1), security_version: "1", time_zone: time_zone)
    RailsAiAdmin::Queries::List.new(zone, SampleAdmin).aggregate(**options)
  end

  def periods(result) = result.groups.map { |group| [ group.key, group.count, group.value ] }

  def test_cross_tab_requires_both_dimensions_and_returns_only_bounded_cells
    with_resources do
      options = { function: "average", field: "amount", group_by: "kind", period_field: "due_on", period: "month" }
      assert_invalid(**options)
      Policy.filter = Policy.filter.merge(agg_samples: %i[kind due_on])
      result = aggregate(**options)
      cells = result.groups.to_h { |cell| [ [ cell.period_start&.iso8601, cell.key ], [ cell.count, cell.value ] ] }
      assert_equal({ [ "2026-11-01", "standard" ] => [ 2, BigDecimal("7.375") ], [ "2026-10-01", "priority" ] => [ 1, BigDecimal("100") ], [ nil, "rush" ] => [ 1, nil ] }, cells)
      assert_equal 4, result.count
      assert_empty aggregate(**options, filters: { kind: { eq: "rush" }, due_on: { gte: "2030-01-01" } }).groups
      15.times do |n|
        %w[standard priority].each { |kind| sample("Cohort", kind: kind, due_on: Date.new(2026, 11, 21) + n) }
      end
      truncated = aggregate(**options.merge(period: "day"))
      assert_equal 25, truncated.groups.size
      assert truncated.groups_truncated
      assert_equal 34, truncated.count
      Policy.filter = Policy.filter.merge(agg_samples: [ :due_on ])
      assert_invalid(**options)
    end
  end

  def test_periods_run_oldest_first_with_empty_periods_and_undated_records
    Policy.filter = Policy.filter.merge(agg_samples: %i[kind due_on seen_at])
    with_resources do
      months = aggregate(function: "sum", field: "amount", group_by: "due_on", period: "month")
      assert_equal [ [ Date.new(2026, 10, 1), 1, BigDecimal("100") ], [ Date.new(2026, 11, 1), 2, BigDecimal("14.75") ], [ nil, 1, nil ] ], periods(months)
      assert_equal [ "month", 4, BigDecimal("114.75") ], [ months.period, months.count, months.value ]
      refute months.groups_truncated
      weeks = aggregate(function: "count", group_by: "due_on", period: "week", filters: { "due_on" => { "gte" => "2026-10-01" } })
      # Mondays from 5 October to 16 November; Sunday 1 November is in the week of 26 October.
      assert_equal [ [ "2026-10-05", 1 ], [ "2026-10-12", 0 ], [ "2026-10-19", 0 ], [ "2026-10-26", 1 ], [ "2026-11-02", 0 ], [ "2026-11-09", 0 ],
        [ "2026-11-16", 1 ] ], weeks.groups.map { |group| [ group.key.iso8601, group.count ] }
      assert_equal [ [ Date.new(2026, 1, 1), 3, nil ] ], periods(aggregate(function: "count", group_by: "due_on", period: "year",
        filters: { "due_on" => { "gte" => "2026-01-01" } }))
      none = aggregate(function: "count", group_by: "due_on", period: "day", filters: { "kind" => { "eq" => "rush" } })
      assert_equal [ [ nil, 1, nil ] ], periods(none), "only undated records leave just the undated group"
    end
  end

  def test_datetime_periods_split_at_midnight_in_the_actors_time_zone
    Policy.filter = Policy.filter.merge(agg_samples: %i[seen_at])
    sample("E", amount: "1", seen_at: "2026-11-03T23:30:00Z")
    with_resources do
      utc = zoned("UTC", function: "count", group_by: "seen_at", period: "day", filters: { "seen_at" => { "gte" => "2026-11-02T00:00:00Z" } })
      assert_equal [ [ Date.new(2026, 11, 3), 2 ] ], utc.groups.map { |group| [ group.key, group.count ] }
      # 23:30 UTC is 08:30 the next morning in Tokyo; 18:30 UTC is 03:30.
      tokyo = zoned("Tokyo", function: "count", group_by: "seen_at", period: "day", filters: { "seen_at" => { "gte" => "2026-11-02T00:00:00Z" } })
      assert_equal [ [ Date.new(2026, 11, 4), 2 ] ], tokyo.groups.map { |group| [ group.key, group.count ] }
      # 18:30 UTC is 10:30 in Los Angeles, 23:30 UTC is 15:30: both on the 3rd.
      pacific = zoned("Pacific Time (US & Canada)", function: "count", group_by: "seen_at", period: "day")
      assert_equal [ Date.new(2026, 11, 1), 1 ], [ pacific.groups.first.key, pacific.groups.first.count ]
      assert_equal [ Date.new(2026, 11, 3), 2 ], [ pacific.groups[2].key, pacific.groups[2].count ]
    end
  end

  def test_periods_are_bounded_to_the_latest
    Policy.filter = Policy.filter.merge(agg_samples: %i[due_on])
    with_resources do
      result = aggregate(function: "count", group_by: "due_on", period: "day")
      days = result.groups.first(25)
      assert_equal 26, result.groups.size, "25 days, then the undated group"
      assert result.groups_truncated
      assert_equal [ Date.new(2026, 10, 27), Date.new(2026, 11, 20) ], [ days.first.key, days.last.key ]
      assert_equal [ nil, 1 ], [ result.groups.last.key, result.groups.last.count ]
      assert_equal 4, result.count, "the total still covers every record"
      assert_equal 2, days.sum(&:count), "the October record falls before the returned days"
    end
  end

  def test_periods_need_a_granted_date_field_and_a_known_period
    with_resources do
      assert_invalid(function: "count", group_by: "due_on", period: "month") # no filter grant
      Policy.filter = Policy.filter.merge(agg_samples: %i[kind due_on])
      assert_invalid(function: "count", group_by: "due_on") # a date is not a category
      assert_invalid(function: "count", group_by: "kind", period: "month")
      assert_invalid(function: "count", group_by: "due_on", period: "quarter")
      assert_invalid(function: "count", period: "month")
      assert_equal 3, aggregate(function: "count", group_by: "due_on", period: "month").groups.size
    end
  end

  def test_a_joined_policy_scope_never_counts_a_record_twice
    with_resources do
      @customer.update!(points: 10)
      2.times { |index| Invoice.create!(account_id: 1, number: "I#{index}", customer: @customer) }
      Policy.join_invoices = true
      result = aggregate(resource: CustomerAdmin, function: "sum", field: "points")
      assert_equal [ 1, 10 ], [ result.count, result.value ]
    end
  end

  def test_fields_need_the_declaration_and_the_current_grants
    with_resources do
      assert_invalid(function: "sum", field: "label")
      assert_invalid(function: "sum", field: "account_id") # declared aggregatable but not granted for reading
      assert_invalid(function: "sum", field: "due_on") # dates take only minimum and maximum
      assert_invalid(function: "median", field: "amount")
      assert_invalid(function: "count", field: "amount")
      assert_invalid(function: "sum", field: nil)
      assert_invalid(function: "count", group_by: "label") # text is not a bounded category
      assert_invalid(function: "count", group_by: "amount")
      Policy.filter = Policy.filter.merge(agg_samples: %i[label amount])
      assert_invalid(function: "count", group_by: "kind") # grouping needs the filter grant
      Policy.read = Policy.read.merge(agg_samples: %i[id label kind])
      assert_invalid(function: "sum", field: "amount")
      assert_invalid(function: "count", scope: "missing")
    end
  end

  def test_the_option_is_declared_on_stored_numbers_and_dates_only
    assert RailsAiAdmin::Field.new(:amount, type: :decimal, aggregatable: true).aggregatable?
    assert_equal %i[minimum maximum], RailsAiAdmin::Field.new(:due_on, type: :date, aggregatable: true).aggregate_functions
    assert_equal [], RailsAiAdmin::Field.new(:points, type: :integer).aggregate_functions
    [ [ :text, true ], [ :boolean, true ], [ :time, true ], [ :integer, "yes" ] ].each do |type, value|
      assert_raises(RailsAiAdmin::ConfigurationError, type.to_s) { RailsAiAdmin::Field.new(:value, type: type, aggregatable: value) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      RailsAiAdmin::Field.new(:total, type: :integer, compute: "TotalComputation", depends_on: [ :points ], aggregatable: true)
    end
  end

  def test_the_tool_describes_and_returns_typed_aggregates
    with_resources do
      chat = new_chat
      admit(chat, "What is the total amount per kind?")
      LLMFixture.tool("describe_resource", { resource: "agg_samples" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "sum", field: "amount", group_by: "kind" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "average", field: "amount" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "minimum", field: "seen_at" })
      LLMFixture.tool("aggregate_records", { resource: "agg_invoices", function: "count", group_by: "customer" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "sum", field: "label" })
      LLMFixture.reply("Done.")
      Invoice.create!(account_id: 1, number: "I-1", customer: @customer)
      Invoice.create!(account_id: 1, number: "I-2", customer: nil)
      drain(chat)
      results = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content) }
      described = results[0]
      assert_equal [ { "field" => "amount", "functions" => %w[sum average minimum maximum] }, { "field" => "due_on", "functions" => %w[minimum maximum] },
        { "field" => "seen_at", "functions" => %w[minimum maximum] } ], described["aggregates"]
      assert_equal %w[kind flagged], described["group_by"]
      assert_equal [], described["group_by_period"], "dates need the filter grant to group"
      assert_equal({ "resource" => "agg_samples", "applied_scope" => nil, "function" => "sum", "field" => "amount", "count" => 4, "value" => "114.75",
        "group_by" => "kind", "groups" => [ { "group" => "standard", "count" => 2, "value" => "14.75" },
          { "group" => "priority", "count" => 1, "value" => "100.00" },
          { "group" => "rush", "count" => 1, "value" => nil } ], "groups_truncated" => false }, results[1].except("surface"))
      assert_match(/\A[0-9a-f-]{36}\z/, results[1]["surface"])
      assert_equal "38.2500", results[2]["value"]
      assert_equal "2026-11-01T09:00:00Z", Time.iso8601(results[3]["value"]).utc.iso8601
      groups = results[4]["groups"].sort_by { |group| group["group"].to_s }
      assert_equal [ [ nil, 1 ], [ { "id" => @customer.id.to_s, "label" => "Alice", "resource" => "agg_customers" }, 1 ] ],
        groups.map { |group| [ group["group"], group["count"] ] }.sort_by { |key, _| key.to_s }
      assert_equal "INVALID_QUERY", results[5]["error"]
      refute_includes results.to_json, "999.99", "another tenant's values never reach a result"
      activity = RailsAiAdmin::Assistant::Transcript.new(context, chat).entries.select { |entry| entry.kind == :activity }.map(&:text)
      assert_includes activity, "Calculated totals in Agg samples"
      assert_includes activity, "Tried to calculate totals in Agg samples (the request was not valid)"
    end
  end

  def test_the_tool_returns_periods_as_first_days_with_the_time_zone_for_datetimes
    Policy.filter = Policy.filter.merge(agg_samples: %i[kind due_on seen_at])
    with_resources do
      chat = new_chat
      admit(chat, "Total amount per month?")
      LLMFixture.tool("describe_resource", { resource: "agg_samples" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "sum", field: "amount", group_by: "due_on", period: "month" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "count", group_by: "seen_at", period: "week" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "count", group_by: "kind", period: "week" })
      LLMFixture.tool("aggregate_records", { resource: "agg_samples", function: "count", group_by: "kind", period: "week", period_field: "seen_at" })
      LLMFixture.reply("Done.")
      drain(chat)
      described, months, weeks, invalid, cohorts = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content) }
      assert_equal %w[due_on seen_at], described["group_by_period"]
      assert_equal({ "resource" => "agg_samples", "applied_scope" => nil, "function" => "sum", "field" => "amount", "count" => 4, "value" => "114.75",
        "group_by" => "due_on", "period" => "month", "groups" => [ { "group" => "2026-10-01", "count" => 1, "value" => "100.00" },
          { "group" => "2026-11-01", "count" => 2, "value" => "14.75" }, { "group" => nil, "count" => 1, "value" => nil } ],
        "groups_truncated" => false }, months.except("surface"))
      assert_match(/\A[0-9a-f-]{36}\z/, months["surface"])
      assert_equal [ "week", "UTC", [ [ "2026-10-26", 1 ], [ "2026-11-02", 1 ], [ nil, 2 ] ] ],
        [ weeks["period"], weeks["time_zone"], weeks["groups"].map { |group| [ group["group"], group["count"] ] } ]
      assert_equal "INVALID_QUERY", invalid["error"]
      assert_equal "UTC", cohorts.fetch("time_zone")
      assert_includes cohorts.fetch("groups"), { "group" => "priority", "period_start" => "2026-11-02", "count" => 1 }
      props = RailsToolViews::Surface.find(cohorts.fetch("surface")).props
      views = RailsAiAdmin::Integrations::ToolViews
      views.with_context(context) do
        assert_equal :seen_at, views.metric_card_data(props).aggregate.period_field.name
        Policy.filter = Policy.filter.merge(agg_samples: [ :kind ])
        assert_nil views.metric_card_data(props)
      end
    end
  end

  def test_a_group_label_follows_the_targets_own_grants
    with_resources do
      Invoice.create!(account_id: 1, number: "I-1", customer: @customer)
      Policy.hidden_customers = true
      chat = new_chat
      admit(chat, "Invoices per customer?")
      LLMFixture.tool("aggregate_records", { resource: "agg_invoices", function: "count", group_by: "customer" })
      LLMFixture.reply("Done.")
      drain(chat)
      group = JSON.parse(chat.messages.where(role: "tool").last.content)["groups"].first["group"]
      assert_nil group["resource"]
      refute_equal "Alice", group["label"]
    end
  end
end
