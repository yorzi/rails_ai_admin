# frozen_string_literal: true

require "test_helper"
require "support/database"

class ScopedAdminCustomerPolicy
  attr_reader :context, :record
  def initialize(context, record)
    @context, @record = context, record
  end
  def index? = true
  def show? = record.account_id == context.tenant.id
  def create? = context.actor.id == 1 && record.new_record? && record.account_id == context.tenant.id
  def update? = context.actor.id == 1 && show?
  def destroy? = update?
  def readable_fields = %i[id name]
  def writable_fields = context.actor.id == 1 ? [ :name ] : []
  def searchable_fields = [ :name ]
  def sortable_fields = []

  class Scope
    def initialize(context, relation)
      @context, @relation = context, relation
    end
    def resolve = @relation.where(account_id: @context.tenant.id)
  end
end

class PunditCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :pundit_customers
  policy "ScopedAdminCustomerPolicy"
  title :name
  fields do
    id :id
    text :name, searchable: :prefix, sortable: true
  end
end

class ScopeLessPolicy
  def initialize(context, record); end
  def index? = true
end
class ScopeLessAdmin < PunditCustomerAdmin
  policy "ScopeLessPolicy"
end
class InheritedScopePolicy < ScopedAdminCustomerPolicy
end
class InheritedScopeAdmin < PunditCustomerAdmin
  policy "InheritedScopePolicy"
end

class PunditAdapterTest < Minitest::Test
  include DatabaseHelpers
  def setup
    reset_database
    @adapter = RailsAiAdmin::Authorization::PunditAdapter.new
  end

  def test_action_and_scope_use_explicit_resource_policy
    scoped = @adapter.scope(context: context, resource: PunditCustomerAdmin, relation: Customer.all)
    assert_equal [ @customer.id ], scoped.pluck(:id)
    assert @adapter.allowed?(context: context, action: :update, resource: PunditCustomerAdmin, record: @customer)
    assert @adapter.allowed?(context: context, action: :create, resource: PunditCustomerAdmin)
    refute @adapter.allowed?(context: context(actor: 2), action: :update, resource: PunditCustomerAdmin, record: @customer)
    refute @adapter.allowed?(context: context, action: :show, resource: PunditCustomerAdmin, record: @other)
    refute @adapter.allowed?(context: context, action: :unknown, resource: PunditCustomerAdmin)
  end

  def test_missing_policy_never_falls_back_to_model_policy
    assert_empty @adapter.scope(context: context, resource: TestResource, relation: Customer.all)
    refute @adapter.allowed?(context: context, action: :index, resource: TestResource)
    assert_empty @adapter.fields(context: context, resource: TestResource, action: :read)
  end

  def test_field_capabilities_are_separate_and_default_to_empty
    assert_equal %i[id name], @adapter.fields(context: context, resource: PunditCustomerAdmin, action: :read, record: @customer)
    assert_equal [ :name ], @adapter.fields(context: context, resource: PunditCustomerAdmin, action: :search)
    assert_empty @adapter.fields(context: context, resource: PunditCustomerAdmin, action: :sort)
    assert_empty @adapter.fields(context: context(actor: 2), resource: PunditCustomerAdmin, action: :write, record: @customer)
    assert_empty @adapter.fields(context: context, resource: PunditCustomerAdmin, action: :export)
  end
  def test_scope_never_inherits_an_unrelated_object_constant
    previous = Object.const_get(:Scope, false) if Object.const_defined?(:Scope, false)
    Object.send(:remove_const, :Scope) if previous
    trap = Class.new do
      def initialize(context, relation)
        @relation = relation
      end
      def resolve = @relation
    end
    Object.const_set(:Scope, trap)
    assert_empty @adapter.scope(context: context, resource: ScopeLessAdmin, relation: Customer.all)
  ensure
    Object.send(:remove_const, :Scope) if Object.const_defined?(:Scope, false)
    Object.const_set(:Scope, previous) if previous
  end

  def test_scope_may_be_explicitly_inherited_from_a_parent_policy
    assert_equal [ @customer.id ], @adapter.scope(context: context, resource: InheritedScopeAdmin, relation: Customer.all).pluck(:id)
  end
  def test_mapping_diagnostics_do_not_grant_access
    assert @adapter.configured?(PunditCustomerAdmin)
    assert @adapter.configured?(InheritedScopeAdmin)
    refute @adapter.configured?(ScopeLessAdmin)
    refute @adapter.configured?(TestResource)
  end
end
