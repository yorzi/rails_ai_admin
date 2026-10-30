require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require "rails_ai_admin/test_kit"

class PackagedAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    RailsAiAdmin::BatchItem.delete_all
    RailsAiAdmin::WorkItem.delete_all
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::SelectionItem.delete_all
    RailsAiAdmin::Selection.delete_all
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

  def test_packaged_custom_type_partial_and_normalization
    login
    get "/staff/customers/#{@customer.id}/edit"
    assert_select "input[data-custom-field=trimmed_text]"
    token = css_select("input[name=authenticity_token]").first["value"]
    intent = css_select("input[name=intent_ref]").first["value"]
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: token, intent_ref: intent, record: { name: "  Cafe\u0301  " } }
    assert_response :see_other
    assert_equal "Café", @customer.reload.name
    get "/staff/customers/#{@customer.id}"
    assert_select "[data-custom-field=trimmed_text]", text: "Café"
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

  def test_custom_operation_native_preview_confirmation_and_replay
    login
    path = "/staff/customers/#{@customer.id}/operations/award_points"
    get path
    assert_response :success
    assert_empty css_select("input[name=intent_ref]")
    token = css_select("input[name=authenticity_token]").first["value"]
    post "#{path}/preflight", params: { authenticity_token: token, expected_version: @customer.lock_version, input: { amount: "08" } }
    assert_response :success
    assert_equal 0, @customer.reload.points
    confirmation = { authenticity_token: css_select("input[name=authenticity_token]").first["value"],
      intent_ref: css_select("input[name=intent_ref]").first["value"], confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
    2.times do
      post "#{path}/execute", params: confirmation
      assert_response :see_other
    end
    assert_equal 8, @customer.reload.points
    assert_equal 1, @customer.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(operation: "award_points", status: "succeeded").count
    assert_empty RailsAiAdmin::WorkItem.all
  end
  def test_native_fixed_selection_requires_csrf_and_current_authority
    login
    get "/staff/customers"
    assert_select "form#raa-selection"
    token = css_select("form#raa-selection input[name=authenticity_token]").first["value"]
    post "/staff/customers/selections", params: { authenticity_token: token, target_ids: [ @customer.id ] }
    assert_response :see_other
    path = URI(response.location).path
    get path
    assert_response :success
    assert_includes response.body, "Packaged Customer"
    assert_equal 0, RailsAiAdmin::OperationRun.count
    @user.update!(role: "viewer")
    get path
    assert_response :not_found
    refute_includes response.body, "Packaged Customer"
  end
  def test_packaged_collection_confirmation_worker_receipt_and_replay
    login
    get "/staff/customers"
    token = css_select("form#raa-selection input[name=authenticity_token]").first["value"]
    post "/staff/customers/selections", params: { authenticity_token: token, target_ids: [ @customer.id ] }
    get URI(response.location).path
    ref = RailsAiAdmin::Selection.first.id
    path = "/staff/customers/operations/bulk_award_points"
    get path, params: { selection_ref: ref }
    token = css_select("input[name=authenticity_token]").first["value"]
    post "#{path}/preflight", params: { authenticity_token: token, selection_ref: ref, input: { amount: "08" } }
    assert_response :success
    confirmation = { authenticity_token: css_select("input[name=authenticity_token]").first["value"],
      intent_ref: css_select("input[name=intent_ref]").first["value"], selection_ref: ref,
      confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
    post "#{path}/execute", params: confirmation
    assert_response :see_other
    job_path = URI(response.location).path
    assert_equal 0, @customer.reload.points
    get job_path
    assert_response :success
    assert_includes response.body, "Queued"
    result = RailsAiAdmin::Collections::Dispatcher.new.run(confirmation[:intent_ref])
    assert_equal "succeeded", result.status
    assert_equal 8, @customer.reload.points
    post "#{path}/execute", params: confirmation
    assert_response :see_other
    assert_equal 8, @customer.reload.points
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    get job_path
    assert_response :success
    assert_includes response.body, "Succeeded"
  end
end
