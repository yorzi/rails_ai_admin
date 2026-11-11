# frozen_string_literal: true

require "test_helper"
require "support/database"
require "rails_ai_admin/test_kit"
require "rails_ai_admin/doctor"

class FilterSampleAdmin < RailsAiAdmin::Resource
  model "FilterSample"
  key :filter_samples
  title :label
  fields do
    id :id
    text :label, filterable: [ :eq ]
    enum :kind, values: %w[standard priority], filterable: true
    decimal :amount, filterable: %i[lte eq gte]
    date :due_on, filterable: true
    datetime :seen_at, filterable: true
    boolean :flagged, filterable: true
    integer :account_id, readonly: true, hidden: true, filterable: true
  end
end

class FiltersTest < Minitest::Test
  include DatabaseHelpers

  ALL = %i[label kind amount due_on seen_at flagged account_id].freeze

  def setup
    reset_database
    TestPolicy.granted_filters = ALL
  end

  def query(filters, resource: FilterSampleAdmin, context: self.context, **options)
    RailsAiAdmin::Queries::List.new(context, resource).call(filters: filters, **options)
  end

  def labels(filters, **options) = query(filters, **options).records.map(&:label).sort
  def sample(label, account_id: 1, **attributes) = FilterSample.create!(account_id: account_id, label: label, **attributes)
  def field(**options) = RailsAiAdmin::Field.new(:value, **options)

  def assert_invalid(filters, **options)
    error = assert_raises(RailsAiAdmin::AccessDenied) { query(filters, **options) }
    assert_equal "INVALID_QUERY", error.code
  end

  def test_declarations_choose_typed_operators_and_reject_unsupported_ones
    assert_equal [ :eq ], field(type: :text, filterable: true).filter_operators
    assert_equal [ :eq ], field(type: :enum, values: %w[a], filterable: true).filter_operators
    assert_equal [ :eq ], field(type: :boolean, filterable: true).filter_operators
    %i[integer decimal date datetime].each { |type| assert_equal %i[gte lte], field(type: type, filterable: true).filter_operators }
    assert_equal %i[eq gte lte], FilterSampleAdmin.fields.find { |entry| entry.name == :amount }.filter_operators
    assert FilterSampleAdmin.fields.all? { |entry| entry.filter_operators.frozen? }
    assert_empty field(type: :integer).filter_operators
    refute field(type: :integer).options.key?(:filterable), "undeclared filters leave existing field contracts unchanged"
    [ { type: :text, filterable: [ :gte ] }, { type: :integer, filterable: [] }, { type: :integer, filterable: %i[gte gte] },
      { type: :integer, filterable: [ "gte" ] }, { type: :integer, filterable: [ :contains ] }, { type: :integer, filterable: "yes" },
      { type: :text, filterable: :eq } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError) { field(**options) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      RailsAiAdmin::Field.new(:summary, type: :text, depends_on: [ :label ], compute: "Summary", filterable: true)
    end
  end

  def test_filter_grants_are_independent_default_deny_and_exclude_hidden_fields
    access = -> { RailsAiAdmin::Authorization::Access.new(context, FilterSampleAdmin) }
    assert_equal %i[label kind amount due_on seen_at flagged], access.call.fields(:filter).map(&:name)
    TestPolicy.granted_filters = []
    assert_empty access.call.fields(:filter)
    TestPolicy.granted_filters = %i[amount id]
    assert_equal [ :amount ], access.call.fields(:filter).map(&:name), "a grant cannot make an undeclared field filterable"
    assert_empty RailsAiAdmin::Authorization::Access.new(context, FilterSampleAdmin).fields(:search)
  end

  def test_typed_conditions_are_anded_bound_and_tenant_scoped
    sample("Alpha", kind: "priority", amount: "10.50", due_on: "2026-11-01", flagged: false)
    sample("Beta", kind: "standard", amount: "10.49", due_on: "2026-11-02", flagged: true)
    sample("Gamma", kind: "priority", amount: "99.00", due_on: "2026-12-01", flagged: false)
    sample("Alpha", account_id: 2, kind: "priority", amount: "10.50", due_on: "2026-11-01")
    assert_equal %w[Alpha Gamma], labels({ "kind" => { "eq" => "priority" } })
    assert_equal %w[Alpha Gamma], labels({ "flagged" => { "eq" => "false" } }), "false is a value, not a blank"
    assert_equal %w[Alpha], labels({ "label" => { "eq" => "Alpha" } })
    assert_empty labels({ "label" => { "eq" => "alpha" } }), "text equality is exact"
    assert_equal %w[Alpha Gamma], labels({ "amount" => { "gte" => "10.50" } })
    assert_equal %w[Alpha], labels({ "amount" => { "eq" => "10.5" } })
    assert_equal %w[Alpha Beta], labels({ "due_on" => { "gte" => "2026-11-01", "lte" => "2026-11-02" } }), "ranges are inclusive"
    assert_equal %w[Alpha], labels({ kind: { eq: "priority" }, due_on: { lte: "2026-11-30" } })
  end

  def test_datetime_values_use_the_authenticated_context_time_zone
    sample("Before", seen_at: Time.utc(2026, 10, 31, 23, 59))
    sample("At", seen_at: Time.utc(2026, 11, 1, 0, 0))
    shanghai = RailsAiAdmin::Context.new(actor: TestActor.new(1), tenant: TestTenant.new(1), security_version: "1", time_zone: "Asia/Shanghai")
    assert_equal %w[At], labels({ "seen_at" => { "gte" => "2026-11-01T08:00" } }, context: shanghai)
    assert_equal %w[At Before], labels({ "seen_at" => { "gte" => "2026-11-01T07:59" } }, context: shanghai)
    assert_equal %w[At], labels({ "seen_at" => { "gte" => "2026-11-01T00:00" } })
  end

  def test_filters_compose_with_scopes_search_sort_and_page_recovery
    TestPolicy.granted_scopes = %i[active all]
    TestPolicy.granted_filters = %i[points active]
    27.times { |index| Customer.create!(account_id: 1, name: "Point #{index.to_s.rjust(2, "0")}", points: index) }
    Customer.create!(account_id: 1, name: "Point inactive", points: 50, active: false)
    Customer.create!(account_id: 2, name: "Point foreign", points: 50)
    list = ->(**options) { RailsAiAdmin::Queries::List.new(context, TestResource).call(**options) }
    filtered = list.call(filters: { "points" => { "gte" => "10", "lte" => "40" } }, search: "Point", sort: "name")
    assert_equal (10..26).map { |index| "Point #{index}" }, filtered.records.map(&:name)
    assert_equal [ "Point inactive" ], list.call(filters: { "active" => { "eq" => "false" } }, scope: "all").records.map(&:name)
    assert_empty list.call(filters: { "active" => { "eq" => "false" } }).records, "the granted default scope still applies"
    page = list.call(filters: { "points" => { "gte" => "20" } }, page: "1000", recover_empty_page: true)
    assert_equal 1, page.number
    assert_equal 7, page.records.size
  end

  def test_ungranted_undeclared_malformed_or_out_of_contract_filters_are_invalid
    TestPolicy.granted_filters = %i[kind amount due_on flagged label]
    [
      { "seen_at" => { "gte" => "2026-11-01T00:00" } }, { "account_id" => { "gte" => "0" } }, { "id" => { "eq" => "1" } },
      { "missing" => { "eq" => "x" } }, { "label" => { "gte" => "A" } }, { "amount" => { "contains" => "1" } },
      { "amount); DROP TABLE filter_samples; --" => { "eq" => "1" } }, { "amount" => { "gte; DROP" => "1" } },
      { "amount" => { "gte" => "abc" } }, { "amount" => { "gte" => "Infinity" } }, { "due_on" => { "gte" => "2026-02-30" } },
      { "flagged" => { "eq" => "maybe" } }, { "kind" => { "eq" => "urgent" } }, { "label" => { "eq" => "bad\u0000value" } },
      { "label" => { "eq" => "x" * 201 } }, { "label" => { "eq" => "" } }, { "label" => { "eq" => 5 } }, { "label" => { "eq" => nil } },
      { "label" => { "eq" => String.new("\xff").force_encoding(Encoding::UTF_8) } }, { "label" => {} }, { "label" => [ "eq" ] },
      { "label" => { "eq" => { "nested" => "x" } } }, [ [ "label", { "eq" => "x" } ] ], "label=x",
      { "amount" => { "eq" => "1", "gte" => "1", "lte" => "1" }, "due_on" => { "gte" => "2026-01-01", "lte" => "2026-01-01" }, "kind" => { "eq" => "standard" }, "flagged" => { "eq" => "true" }, "label" => { "eq" => "x" } }.merge(15.times.to_h { |index| [ "extra_#{index}", { "eq" => "x" } ] })
    ].each { |filters| assert_invalid(filters) }
    assert FilterSample.table_exists?
  end

  def test_list_hints_carry_canonical_filters_and_drop_revoked_or_blank_values
    access = -> { RailsAiAdmin::Authorization::Access.new(context, FilterSampleAdmin) }
    state = ->(raw, **options) { RailsAiAdmin::Navigation::ListState.new(access.call, raw, **options) }
    hint = state.call({ filter: { flagged: { eq: "false" }, amount: { lte: "20", gte: "10", eq: "" }, label: { eq: " " } }, page: "2" }, strict: true)
    assert_equal({ "page" => "2", "filter" => { "amount" => { "gte" => "10", "lte" => "20" }, "flagged" => { "eq" => "false" } } }, hint.state)
    assert_equal [ "amount", "flagged" ], hint.state["filter"].keys
    refute hint.discarded?
    assert hint.state["filter"].frozen?
    assert hint.state.dig("filter", "amount").frozen?
    assert_raises(FrozenError) { hint.state.dig("filter", "amount", "gte") << "0" }
    assert_equal hint.state, RailsAiAdmin::Navigation::ListState.from_header(access.call, hint.encoded).state
    assert_equal [ [ "return_to[page]", "2" ], [ "return_to[filter][amount][gte]", "10" ], [ "return_to[filter][amount][lte]", "20" ], [ "return_to[filter][flagged][eq]", "false" ] ],
      RailsAiAdmin::Navigation::ListState.form_pairs(hint.state, "return_to")

    [ { filter: { missing: { eq: "x" } } }, { filter: { label: { gte: "x" } } }, { filter: { account_id: { gte: "1" } } },
      { filter: { amount: { gte: "abc" } } }, { filter: "amount" }, { filter: { amount: { gte: [ "1" ] } } } ].each do |raw|
      assert_raises(RailsAiAdmin::AccessDenied) { state.call(raw, strict: true) }
      relaxed = state.call(raw)
      assert relaxed.discarded?
      assert_nil relaxed.state["filter"]
    end

    TestPolicy.granted_filters = %i[flagged]
    revoked = state.call({ q: "x", filter: { amount: { gte: "10" }, flagged: { eq: "true" } }, page: "3" }, strict: true)
    assert revoked.discarded?
    assert_equal({ "filter" => { "flagged" => { "eq" => "true" } } }, revoked.state.except("q"))
  end

  def test_pundit_and_test_kit_report_filter_grants
    policy = Class.new do
      def initialize(context, record) = @context = context
      def filterable_fields = @context.actor.id == 1 ? %i[kind amount] : []
    end
    self.class.const_set(:PunditFilters, policy) unless self.class.const_defined?(:PunditFilters, false)
    resource = Class.new(FilterSampleAdmin) do
      model "FilterSample"
      policy "FiltersTest::PunditFilters"
    end
    adapter = RailsAiAdmin::Authorization::PunditAdapter.new
    assert_equal %i[kind amount], adapter.fields(context: context, resource: resource, action: :filter)
    assert_empty adapter.fields(context: context(actor: 2), resource: resource, action: :filter)
    assert_equal %w[amount due_on flagged kind label seen_at], RailsAiAdmin::TestKit.field_grants(context: context, resource: FilterSampleAdmin).fetch("filter")
    assert_raises(RailsAiAdmin::TestKit::AssertionError) { RailsAiAdmin::TestKit.assert_hidden(context: context, resource: FilterSampleAdmin, field: :amount, actions: [ :filter ]) }
  end

  def test_doctor_reviews_filterable_columns_without_an_index
    checks = RailsAiAdmin::Doctor.new(configuration: RailsAiAdmin::Configuration.new, registry: RailsAiAdmin::Registry.new([ "FilterSampleAdmin" ]), application: nil).checks
    check = checks.find { |entry| entry.name == "filter_indexes:filter_samples" }
    assert_equal :review, check.status
    # RAA-026: the line names what it counts.
    assert_match(/\AFilterable declarations in no index: 6 fields \(label, kind, amount, due_on, seen_at, flagged\)/, check.message)
  end
end
