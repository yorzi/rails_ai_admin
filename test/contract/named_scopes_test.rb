# frozen_string_literal: true

require "test_helper"
require "support/database"
require "minitest/mock"
require "rails_ai_admin/test_kit"

class EscapingScopeAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :escaping_customers
  title :name
  fields do
    id :id
    text :name, searchable: :prefix, sortable: true
  end
  scopes do
    scope :unscoped_body, -> { unscoped }
    scope :foreign_tenant, -> { where(account_id: 2) }
    scope :widened, -> { where(name: "Alice").or(Customer.where(account_id: 2)) }
    scope :self_join, -> { joins("INNER JOIN customers peers ON peers.account_id = customers.account_id") }
    scope :model_scope, -> { named_alice }
  end
end

class InvalidScopeAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :invalid_scope_customers
  title :name
  fields do
    id :id
    text :name
  end
  scopes do
    scope :limited, -> { limit(1) }
    scope :selected, -> { select(:name) }
    scope :grouped, -> { group(:name) }
    scope :eager, -> { includes(:nothing) }
    scope :other_model, -> { UuidCustomer.all }
    scope :not_relation, -> { [ 1, 2 ] }
    scope :raises, -> { raise "secret host detail" }
    scope :writes, -> { Customer.update_all(name: "Written by a scope"); all }
  end
end

class Customer
  scope :named_alice, -> { where(name: "Alice") }
end

class NamedScopesTest < Minitest::Test
  include DatabaseHelpers

  class AllScopesPolicy < TestPolicy
    def named_scopes(context:, resource:) = resource.scopes.map(&:name)
  end

  def setup
    reset_database
  end

  def query(resource = TestResource, **options) = RailsAiAdmin::Queries::List.new(context, resource).call(**options)
  def names(page) = page.records.map(&:name).sort

  def with_policy(policy, &block)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = policy.name
    RailsAiAdmin.stub(:configuration, config, &block)
  end

  def declare(&block)
    Class.new(RailsAiAdmin::Resource) do
      model "Customer"
      key :declared_customers
      title :name
      fields { text :name }
      scopes(&block)
    end
  end

  def test_declarations_are_bounded_lazy_and_frozen
    [
      proc { scope "Bad" }, proc { scope :"has-dash" }, proc { scope(("x" * 41).to_sym) }, proc { scope 1 },
      proc { scope :proc_body, proc { all } }, proc { scope :argument, ->(value) { where(name: value) } },
      proc { scope :bad_default, default: "yes" }, proc { scope :bad_label, label: "line\nbreak" },
      proc { scope :blank_label, label: "   " }, proc { scope :long_label, label: "x" * 81 },
      proc { scope :twice; scope :twice }, proc { scope :one, default: true; scope :two, default: true },
      proc { 21.times { |index| scope :"scope_#{index}" } }
    ].each do |declaration|
      assert_raises(RailsAiAdmin::ConfigurationError) { declare(&declaration) }
    end
    evaluated = false
    resource = declare do
      scope :pending, -> { evaluated = true; where(name: "pending") }, default: true
      scope :all, label: "全部 records"
    end
    refute evaluated, "declaring a scope must not evaluate its body"
    assert_equal [ :pending, :all ], resource.scopes.map(&:name)
    assert_equal [ "Pending", "全部 records" ], resource.scopes.map(&:label)
    assert resource.scopes.first.default?
    assert resource.scopes.all?(&:frozen?)
    assert resource.scopes.map(&:label).all?(&:frozen?)
    assert_raises(FrozenError) { TestResource.scopes { scope :late } }
  end

  def test_scopes_are_default_deny_and_granted_in_declaration_order
    assert_empty RailsAiAdmin::Authorization::Access.new(context, TestResource).named_scopes
    TestPolicy.granted_scopes = [ "all", :active, :unknown ]
    assert_equal %i[active all], RailsAiAdmin::Authorization::Access.new(context, TestResource).named_scopes.map(&:name)
    [ "all", [ 1 ], [ nil ], { all: true } ].each do |grant|
      TestPolicy.granted_scopes = grant
      assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Authorization::Access.new(context, TestResource).named_scopes }
    end
    TestPolicy.granted_scopes = [ :all ]
    TestPolicy.denied = true
    assert_empty RailsAiAdmin::Authorization::Access.new(context, TestResource).named_scopes
  end

  def test_granted_default_narrows_and_explicit_scopes_require_current_grants
    Customer.create!(account_id: 1, name: "Bob", active: false, points: 5)
    Customer.create!(account_id: 1, name: "Carol", points: 3)
    assert_equal %w[Alice Bob Carol], names(query)
    assert_nil query.scope
    error = assert_raises(RailsAiAdmin::AccessDenied) { query(scope: "active") }
    assert_equal "INVALID_QUERY", error.code

    TestPolicy.granted_scopes = %i[active rewarded all]
    assert_equal %w[Alice Carol], names(query)
    assert_equal "active", query.scope
    assert_equal %w[Bob Carol], names(query(scope: "rewarded"))
    assert_equal %w[Alice Bob Carol], names(query(scope: "all"))
    assert_equal "all", query(scope: "all").scope

    TestPolicy.granted_scopes = %i[rewarded]
    assert_equal %w[Alice Bob Carol], names(query), "an ungranted default falls back to the policy relation"
    assert_nil query.scope
    [ "active", "missing", "Active", "rewarded; DROP TABLE customers", "", "x" * 41, String.new("\xff").force_encoding(Encoding::UTF_8), "rewarded".encode(Encoding::UTF_16LE), :rewarded, [] ].each do |scope|
      error = assert_raises(RailsAiAdmin::AccessDenied) { query(scope: scope) }
      assert_equal "INVALID_QUERY", error.code
    end
  end

  def test_scopes_compose_with_search_sort_pagination_and_empty_page_recovery
    TestPolicy.granted_scopes = %i[active all]
    expected = 27.times.map { |index| Customer.create!(account_id: 1, name: "Scoped #{index.to_s.rjust(2, "0")}") }
    5.times { |index| Customer.create!(account_id: 1, name: "Scoped inactive #{index}", active: false) }
    30.times { |index| Customer.create!(account_id: 2, name: "Scoped foreign #{index}") }
    first = query(search: "Scoped", sort: "name", direction: "asc")
    second = query(search: "Scoped", sort: "name", direction: "asc", page: "2")
    assert_equal expected.map(&:id), (first.records + second.records).map(&:id)
    assert_equal 32, query(search: "Scoped", scope: "all").records.size + query(search: "Scoped", scope: "all", page: "2").records.size
    page = query(search: "Scoped", page: "1000", recover_empty_page: true)
    assert_equal 2, page.number
    assert_equal 2, page.records.size
    assert_equal "active", page.scope
  end

  def test_scope_bodies_only_narrow_the_policy_relation
    Customer.create!(account_id: 2, name: "Alice")
    Customer.create!(account_id: 1, name: "Bob")
    with_policy(AllScopesPolicy) do
      %w[unscoped_body foreign_tenant widened model_scope].each do |scope|
        page = query(EscapingScopeAdmin, scope: scope)
        assert page.records.all? { |record| record.account_id == 1 }, "#{scope} widened the tenant scope"
      end
      assert_equal %w[Alice Bob], names(query(EscapingScopeAdmin, scope: "unscoped_body"))
      assert_empty query(EscapingScopeAdmin, scope: "foreign_tenant").records
      assert_equal %w[Alice], names(query(EscapingScopeAdmin, scope: "widened"))
      assert_equal %w[Alice], names(query(EscapingScopeAdmin, scope: "model_scope"))
      joined = query(EscapingScopeAdmin, scope: "self_join").records
      assert_equal joined.map(&:id).uniq, joined.map(&:id), "joined scopes must not duplicate rows"
      assert_equal %w[Alice Bob], joined.map(&:name).sort
    end
  end

  def test_unsupported_failing_and_writing_bodies_fail_closed_without_detail
    with_policy(AllScopesPolicy) do
      InvalidScopeAdmin.scopes.map(&:name).each do |scope|
        error = assert_raises(RailsAiAdmin::ConfigurationError) { query(InvalidScopeAdmin, scope: scope.to_s) }
        refute_includes error.message, "secret host detail"
        assert_nil error.cause
      end
    end
    refute Customer.where(name: "Written by a scope").exists?
  end

  def test_pundit_policy_grants_named_scopes_explicitly
    policy = Class.new do
      def initialize(context, record) = @context = context
      def permitted_named_scopes = @context.actor.id == 1 ? %i[active all] : []
    end
    resource = Class.new(RailsAiAdmin::Resource) do
      model "Customer"
      policy "NamedScopesTest::PunditScopes"
    end
    self.class.const_set(:PunditScopes, policy) unless self.class.const_defined?(:PunditScopes, false)
    adapter = RailsAiAdmin::Authorization::PunditAdapter.new
    assert_equal %i[active all], adapter.named_scopes(context: context, resource: resource)
    assert_empty adapter.named_scopes(context: context(actor: 2), resource: resource)
    assert_empty adapter.named_scopes(context: context, resource: TestResource), "no explicit policy grants nothing"
  end

  def test_test_kit_snapshots_current_named_scope_grants
    assert RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: TestResource, expected: [])
    TestPolicy.granted_scopes = %i[all active]
    assert_equal %w[active all], RailsAiAdmin::TestKit.named_scope_grants(context: context, resource: TestResource)
    assert RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: TestResource, expected: %w[all active])
    assert_raises(RailsAiAdmin::TestKit::AssertionError) do
      RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: TestResource, expected: [ :active ])
    end
    assert_raises(ArgumentError) { RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: TestResource, expected: "active") }
  end
end
