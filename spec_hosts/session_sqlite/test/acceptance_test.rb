require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require "rails_ai_admin/test_kit"

class PackagedAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::AuditEvent.delete_all
    Customer.delete_all
    User.delete_all
    Account.delete_all
    @account = Account.create!(name: "Tenant A")
    other = Account.create!(name: "Tenant B")
    @user = User.create!(account: @account, email: "admin@example.test", password: "synthetic-fixture-password", role: "admin")
    @customer = Customer.create!(account: @account, name: "Packaged Customer", secret: "private fixture")
    Customer.create!(account: other, name: "Other tenant")
  end

  def login
    get "/login"
    token = css_select("input[name=authenticity_token]").first["value"]
    post "/login", params: { authenticity_token: token, email: @user.email, password: "synthetic-fixture-password" }
    assert_equal 303, response.status
  end

  def test_packaged_no_ai_crud_and_boundaries
    spec = Gem.loaded_specs.fetch("rails_ai_admin")
    assert_includes spec.full_gem_path, "/gems/rails_ai_admin-"
    refute defined?(RubyLLM)
    refute defined?(RailsToolViews)
    refute ActiveRecord::Base.connection.tables.any? { |table| table.include?("assistant") || table.include?("tool_views") }
    assert_equal "Ai", "ai".camelize
    assert_equal Ai, "Ai".constantize
    get "/staff/customers"
    assert_equal 401, response.status
    login
    get "/staff/customers"
    assert_equal 200, response.status
    assert_includes response.body, "Packaged Customer"
    refute_includes response.body, "Other tenant"
    refute_includes response.body, "private fixture"
    assert_match(/nonce-/, response.headers["Content-Security-Policy"])
    get "/staff/customers/#{@customer.id}/edit"
    token = css_select("input[name=authenticity_token]").first["value"]
    intent = css_select("input[name=intent_ref]").first["value"]
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: token, intent_ref: intent, record: { name: "Installed from gem", points: "08" } }
    assert_equal 303, response.status
    assert_equal "Installed from gem", @customer.reload.name
    assert_equal 8, @customer.points
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: token, intent_ref: intent, record: { name: "Installed from gem", points: "08" } }
    assert_equal 303, response.status
    assert_equal 1, @customer.reload.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    get "/staff/directory/#{@customer.id}/edit"
    assert_equal 404, response.status
    context = RailsAiAdmin::Context.new(actor: @user, tenant: @account, security_version: "1")
    assert RailsAiAdmin::TestKit.assert_hidden(context: context, resource: CustomerAdmin, field: :secret)
    assert RailsAiAdmin::TestKit.assert_isolated(context: context, resource: CustomerAdmin, foreign_id: Customer.where.not(account_id: @account.id).first.id)
  end

  def test_host_policy_matrix_and_field_grants
    anonymous = Struct.new(:session).new({})
    assert RailsAiAdmin::TestKit.assert_unauthenticated(adapter: AdminContext.new, controller: anonymous)
    %w[admin viewer].each do |role|
      @user.update!(role: role)
      context = RailsAiAdmin::Context.new(actor: @user, tenant: @account, security_version: @user.security_version.to_s)
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: CustomerAdmin, action: :update, record: @customer, allowed: role == "admin")
      assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: CustomerAdmin, record: @customer,
        expected: { read: %i[id name active points created_at], write: role == "admin" ? %i[name active points] : [], search: [ :name ], sort: [ :name ] })
      assert RailsAiAdmin::TestKit.assert_hidden(context: context, resource: CustomerAdmin, field: :secret)
    end
    context = RailsAiAdmin::Context.new(actor: @user, tenant: @account, security_version: @user.security_version.to_s)
    assert RailsAiAdmin::TestKit.assert_isolated(context: context, resource: CustomerAdmin, foreign_id: Customer.where.not(account_id: @account.id).first.id)
  end
end
