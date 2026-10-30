require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require "rails_ai_admin/test_kit"

require_relative "override_render_tracker" if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"

class PackagedAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    RailsAiAdmin::BatchItem.delete_all
    RailsAiAdmin::WorkItem.delete_all
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::SelectionItem.delete_all
    RailsAiAdmin::Selection.delete_all
    RailsAiAdmin::AuditEvent.delete_all
    Order.delete_all
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

  if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"
    def test_generated_host_template_precedence_and_form_contract
      login
      get "/staff"
      assert_response :success
      assert_select "[data-raa-override=layout]"
      assert_select "[data-raa-override=dashboard]"
      get "/staff/customers"
      assert_select "[data-raa-override=resource_index]"
      assert_select "[data-raa-override=field_index]"
      get "/staff/customers/#{@customer.id}"
      assert_select "[data-raa-override=resource_show]"
      assert_select "[data-raa-override=field_show]"
      get "/staff/customers/new"
      assert_select "[data-raa-override=resource_new]"
      assert_select "[data-raa-override=resource_form]"
      assert_select "[data-raa-override=field_form]"
      assert_select "[data-raa-override=input_fields]"
      get "/staff/customers/#{@customer.id}/edit"
      assert_select "[data-raa-override=resource_edit]"
      assert_select "form", count: 1
      assert_select "input[name=intent_ref]", count: 1
      assert_select "input[name=authenticity_token]", count: 1
      token = css_select("input[name=authenticity_token]").first["value"]
      intent = css_select("input[name=intent_ref]").first["value"]
      patch "/staff/customers/#{@customer.id}", params: { authenticity_token: token, intent_ref: intent, record: { name: "" } }
      assert_response :unprocessable_content
      assert_select "[data-raa-override=resource_edit]"
      assert_select "[data-raa-override=resource_errors]"
      assert_equal "Packaged Customer", @customer.reload.name
      get "/staff/customers/#{@customer.id}/confirm_destroy"
      assert_response :success
      assert_select "[data-raa-override=resource_destroy]"
      assert_equal 1, response.body.scan(/<!DOCTYPE/i).size

      member_path = "/staff/customers/#{@customer.id}/operations/award_points"
      get member_path
      post "#{member_path}/preflight", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], expected_version: @customer.lock_version, input: { amount: "1" } }
      assert_response :success
      confirmation = { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: css_select("input[name=intent_ref]").first["value"], confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
      @customer.update!(points: 1)
      post "#{member_path}/execute", params: confirmation
      assert_response :conflict
      assert_select "[data-raa-override=operation_failure]"
      assert_equal 1, @customer.reload.points

      get "/staff/customers"
      post "/staff/customers/selections", params: { authenticity_token: css_select("form#raa-selection input[name=authenticity_token]").first["value"], target_ids: [ @customer.id ] }
      get URI(response.location).path
      selection_ref = RailsAiAdmin::Selection.order(:created_at).last.id
      collection_path = "/staff/customers/operations/bulk_award_points"
      get collection_path, params: { selection_ref: selection_ref }
      assert_select "[data-raa-override=collection_form]"
      post "#{collection_path}/preflight", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], selection_ref: selection_ref, input: { amount: "1" } }
      assert_select "[data-raa-override=collection_confirmation]"
      confirmation = { authenticity_token: css_select("input[name=authenticity_token]").first["value"], selection_ref: selection_ref, intent_ref: css_select("input[name=intent_ref]").first["value"], confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
      @customer.update!(points: 2)
      post "#{collection_path}/execute", params: confirmation
      assert_response :conflict
      assert_select "[data-raa-override=collection_failure]"
      assert_equal 2, @customer.reload.points
      get "/staff/jobs"
      assert_response :success
      assert_select "[data-raa-override=job_index]"
    end
  end

  def test_resource_menu_groups_icons_and_hidden_alias_preserve_native_authority
    login
    get "/staff"
    assert_response :success
    assert_select "nav[aria-label='Admin resources'] h2", text: "People"
    assert_select "nav[aria-label='Admin resources'] h2", text: "Commerce"
    assert_select "nav a[href='/staff/customers'] svg[aria-hidden=true][focusable=false]"
    assert_select "nav a[href='/staff/orders'] svg[aria-hidden=true][focusable=false]"
    assert_select "nav a[href='/staff/directory']", count: 0
    assert_select ".raa-cards a[href='/staff/directory']", count: 0
    get "/staff/directory"
    assert_response :success
    get "/staff/directory/#{@customer.id}"
    assert_response :success
    get "/staff/customers/#{@customer.id}"
    assert_select "nav a[href='/staff/customers'][aria-current=location]"
  end

  def test_order_native_crud_preserves_decimal_date_false_and_denies_readonly_input
    login
    get "/staff/orders/new"
    assert_response :success
    ref = css_select("input[name=intent_ref]").first["value"]
    input = { number: "ORD-100", total: "-1.25", delivery_on: "2026-11-02", expedited: "false" }
    post "/staff/orders", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: input }
    assert_response :unprocessable_content
    assert_select "input[name='record[total]'][value='-1.25']"
    assert_equal 0, Order.count
    input[:total] = "123.456"
    post "/staff/orders", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: input }
    assert_response :unprocessable_content
    assert_equal 0, Order.count
    input[:total] = "123.45"
    post "/staff/orders", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: input }
    assert_response :see_other
    order = Order.find_by!(number: "ORD-100")
    assert_equal @account.id, order.account_id
    assert_equal BigDecimal("123.45"), order.total
    assert_equal Date.new(2026, 11, 2), order.delivery_on
    refute order.expedited
    assert_equal "draft", order.state
    get "/staff/orders/#{order.id}/edit"
    assert_response :success
    assert_select "input[name='record[state]']", count: 0
    assert_select "select[name='record[state]']", count: 0
    ref = css_select("input[name=intent_ref]").first["value"]
    @user.increment!(:security_version)
    get "/staff/orders/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref }
    assert_response :success
    assert_equal "ready", response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_equal @user.security_version.to_s, RailsAiAdmin::OperationRun.find(ref).security_version
    assert_select "input[name='record[total]'][value='123.45']"
    assert_select "input[name='record[delivery_on]'][value='2026-11-02']"
    assert_select "select[name='record[expedited]'] option[selected][value=false]"
    patch "/staff/orders/#{order.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: { state: "approved" } }
    assert_response :unprocessable_content
    assert_equal "draft", order.reload.state
    patch "/staff/orders/#{order.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: { delivery_on: "2026-02-30" } }
    assert_response :unprocessable_content
    assert_equal Date.new(2026, 11, 2), order.reload.delivery_on
    patch "/staff/orders/#{order.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: { total: "0", expedited: "true" } }
    assert_response :see_other
    assert_equal BigDecimal("0"), order.reload.total
    assert order.expedited
    get "/staff/orders/#{order.id}"
    assert_response :success
    assert_includes response.body, "ORD-100 · draft · 0.0"
    get "/staff/orders/#{order.id}/confirm_destroy"
    delete "/staff/orders/#{order.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: css_select("input[name=intent_ref]").first["value"] }
    assert_response :see_other
    refute Order.exists?(order.id)
    assert_equal 3, RailsAiAdmin::AuditEvent.where(resource_key: "orders", status: "succeeded").count
  end

  def test_host_order_workbench_and_native_action_consume_the_same_confirmed_intent_once
    login
    order = Order.create!(account: @account, number: "ORD-REVIEW", total: "123.45", secret_payment_token: "private-payment-fixture")
    path = "/staff/workbench/orders/#{order.id}"
    get path
    assert_response :success
    assert_select "h1", text: "Order review workbench"
    assert_select "form[data-turbo=false]"
    nonce = css_select("meta[name=csp-nonce]").first["content"]
    assert_includes response.headers["Content-Security-Policy"], "'nonce-#{nonce}'"
    refute_includes response.body, "private-payment-fixture"
    post "#{path}/preview", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], expected_version: 0, input: { decision: "approve", note: "   " } }
    assert_response :unprocessable_content
    assert_equal "draft", order.reload.state
    assert_empty RailsAiAdmin::OperationRun.where(resource_key: "orders")
    post "#{path}/preview", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], expected_version: 0, input: { decision: "approve", note: "  Checked total and delivery  " } }
    assert_response :success
    assert_select "h1", text: "Confirm order review"
    assert_equal "draft", order.reload.state
    ref = css_select("input[name=intent_ref]").first["value"]
    wire = css_select("input[name=confirmed_input]").first["value"]
    global_csrf = css_select("meta[name=csrf-token]").first["content"]
    post "/staff/orders/#{order.id}/operations/review_order/execute", params: { authenticity_token: global_csrf, intent_ref: ref, confirmed_input: wire }
    assert_response :see_other
    post "#{path}/execute", params: { authenticity_token: global_csrf, intent_ref: ref, confirmed_input: wire }
    assert_response :see_other
    assert_equal "approved", order.reload.state
    assert_equal "Checked total and delivery", order.review_note
    assert order.reviewed_at
    assert_equal 1, order.lock_version
    assert_equal 1, RailsAiAdmin::OperationRun.where(resource_key: "orders").count
    assert_equal 1, RailsAiAdmin::AuditEvent.where(resource_key: "orders", operation: "review_order", status: "succeeded", correlation_ref: ref).count
    get "/staff/orders/#{order.id}/edit"
    assert_response :not_found
    post "#{path}/execute", params: { authenticity_token: global_csrf, intent_ref: ref, confirmed_input: JSON.generate(decision: "reject", note: "Changed after confirmation") }
    assert_response :conflict
    assert_equal "approved", order.reload.state
    assert_equal 1, order.lock_version
  end

  def test_order_workbench_rechecks_tenant_role_and_version_without_secret_projection
    login
    order = Order.create!(account: @account, number: "ORD-LOCAL", total: "9.99", review_note: "Admin-only order context")
    foreign_account = Account.where.not(id: @account.id).first
    foreign = Order.create!(account: foreign_account, number: "ORD-FOREIGN", total: "8.88", secret_payment_token: "private foreign payment")
    get "/staff/workbench/orders/#{foreign.id}"
    assert_response :not_found
    refute_includes response.body, "ORD-FOREIGN"
    refute_includes response.body, "private foreign payment"
    path = "/staff/workbench/orders/#{order.id}"
    get path
    token = css_select("input[name=authenticity_token]").first["value"]
    order.update!(total: "10.00")
    post "#{path}/preview", params: { authenticity_token: token, expected_version: 0, input: { decision: "approve", note: "Old version" } }
    assert_response :conflict
    assert_equal "draft", order.reload.state
    assert_empty RailsAiAdmin::OperationRun.where(resource_key: "orders")
    @user.update!(role: "viewer")
    get path
    assert_response :success
    viewer_csrf = css_select("meta[name=csrf-token]").first["content"]
    assert_select "form", count: 0
    refute_includes response.body, "Admin-only order context"
    get "/staff/orders/#{order.id}/edit"
    assert_response :not_found
    post "#{path}/preview", params: { authenticity_token: viewer_csrf, expected_version: order.lock_version, input: { decision: "approve", note: "Forbidden review" } }
    assert_response :not_found
    assert_equal "draft", order.reload.state
    assert_empty RailsAiAdmin::AuditEvent.where(resource_key: "orders", status: "succeeded")
  end

  def test_unicode_list_navigation_survives_edit_recovery_and_filtered_page_deletion
    login
    @customer.update!(name: "客户 🚀 00")
    25.times { |index| Customer.create!(account: @account, name: "客户 🚀 #{(index + 1).to_s.rjust(2, '0')}") }
    state = { "q" => "客户 🚀", "sort" => "name", "direction" => "desc", "page" => "2" }
    get "/staff/customers", params: state
    assert_response :success
    view = css_select("main a").find { |node| node.text.start_with?("View ") }
    assert_equal state, Rack::Utils.parse_nested_query(URI(view["href"]).query)["return_to"]
    get view["href"]
    edit = css_select("main a").find { |node| node.text == "Edit" }
    get edit["href"]
    assert_response :success
    ref = css_select("input[name=intent_ref]").first["value"]
    encoded = css_select("form[data-raa-form-recovery-return-state-value]").first["data-raa-form-recovery-return-state-value"]
    assert encoded.ascii_only?
    get "/staff/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref, "X-RailsAiAdmin-Return-State" => encoded }
    assert_response :success
    assert_select "input[name='return_to[q]'][value='客户 🚀']"
    cancel = css_select("main a").find { |node| node.text == "Cancel" }
    assert_equal state, Rack::Utils.parse_nested_query(URI(cancel["href"]).query)
    get "/staff/customers/#{@customer.id}/confirm_destroy", params: { return_to: state }
    assert_response :success
    delete "/staff/customers/#{@customer.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: css_select("input[name=intent_ref]").first["value"], return_to: state }
    assert_response :see_other
    follow_redirect!
    assert_response :see_other
    assert_equal state.except("page"), Rack::Utils.parse_nested_query(URI(response.location).query)
    follow_redirect!
    assert_response :success
    assert_select "tbody tr", count: 25
    refute_includes response.body, "Other tenant"
  end

  def test_authenticated_recovery_reuses_the_original_intent_after_session_loss
    login
    get "/staff/customers/#{@customer.id}/edit"
    ref = css_select("input[name=intent_ref]").first["value"]
    reset!
    get "/login"
    anonymous_csrf = css_select("input[name=authenticity_token]").first["value"]
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: anonymous_csrf, intent_ref: ref, record: { name: "Must not execute" } }
    assert_response :unprocessable_content
    assert_equal "session", response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_equal "Packaged Customer", @customer.reload.name
    login
    get "/staff/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref }
    assert_response :success
    assert_equal "ready", response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_select "input[name=intent_ref][value='#{ref}']"
    assert_select "a[href='/login'][target=_blank][rel='noopener noreferrer']"
    assert_equal 1, RailsAiAdmin::OperationRun.count
    assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: ref, record: { name: "Explicit recovered save" } }
    assert_response :see_other
    assert_equal "Explicit recovered save", @customer.reload.name
    get "/staff/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref }
    assert_response :not_found
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
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
    assert_select ".raa-tab-links a", count: 2
    assert_select "section[hidden]", count: 0
    assert_select "fieldset legend", text: "Rewards"
    assert_select "output", minimum: 2
    assert_select ".raa-field-help", text: "Use whole points."
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

  def test_packaged_computed_summary_is_derived_and_cannot_be_written
    login
    get "/staff/customers/#{@customer.id}"
    assert_select "dd", text: "Active · 0 points"
    get "/staff/customers/#{@customer.id}/edit"
    assert_select "input[name='record[status_summary]']", count: 0
    token = css_select("input[name=authenticity_token]").first["value"]
    intent = css_select("input[name=intent_ref]").first["value"]
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: token, intent_ref: intent, record: { status_summary: "Forged" } }
    assert_response :unprocessable_content
    assert_equal 0, @customer.reload.points
    patch "/staff/customers/#{@customer.id}", params: { authenticity_token: css_select("input[name=authenticity_token]").first["value"], intent_ref: intent, record: { points: "8", active: "false" } }
    assert_response :see_other
    get "/staff/customers/#{@customer.id}"
    assert_select "dd", text: "Inactive · 8 points"
  end

  def test_host_policy_matrix_and_field_grants
    anonymous = Struct.new(:session).new({})
    assert RailsAiAdmin::TestKit.assert_unauthenticated(adapter: AdminContext.new, controller: anonymous)
    %w[admin viewer].each do |role|
      @user.update!(role: role)
      context = RailsAiAdmin::Context.new(actor: @user, tenant: @account, security_version: @user.security_version.to_s)
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: CustomerAdmin, action: :update, record: @customer, allowed: role == "admin")
      assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: CustomerAdmin, record: @customer,
        expected: { read: %i[id name active points created_at status_summary], write: role == "admin" ? %i[name active points] : [], search: [ :name ], sort: [ :name ] })
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
