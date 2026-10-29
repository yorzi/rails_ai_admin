require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require "webmock/minitest"
require "rails_ai_admin/test_kit"
WebMock.disable_net_connect!

class SupportHostAcceptanceTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  def setup
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::AuditEvent.delete_all
    SupportTicket.delete_all
    TenantMembership.delete_all
    StaffUser.delete_all
    Tenant.delete_all
    @tenant = Tenant.create!(name: "Tenant A")
    @other_tenant = Tenant.create!(name: "Tenant B")
    @outsider = Tenant.create!(name: "Not a membership")
    @staff = StaffUser.create!(email: "staff@example.test", password: "synthetic-fixture-password", role: "admin")
    [ @tenant, @other_tenant ].each { |tenant| @staff.tenant_memberships.create!(tenant: tenant) }
    @ticket = SupportTicket.create!(tenant: @tenant, subject: "Support task", internal_note: "restricted note", secret_token: "never exposed")
    @foreign = SupportTicket.create!(tenant: @other_tenant, subject: "Other tenant task")
  end

  def csrf
    css_select("input[name=authenticity_token]").first["value"]
  end

  def login
    get "/staff_users/sign_in"
    assert_response :success
    post "/staff_users/sign_in", params: { authenticity_token: csrf, staff_user: { email: @staff.email, password: "synthetic-fixture-password" } }
    assert_response :see_other
  end

  def edit_intent
    get "/operations/tickets/#{@ticket.id}/edit"
    assert_response :success
    [ csrf, css_select("input[name=intent_ref]").first["value"] ]
  end

  def test_packaged_dependencies_and_boot_boundaries
    assert_includes Gem.loaded_specs.fetch("rails_ai_admin").full_gem_path, "/gems/rails_ai_admin-"
    assert_equal "PunditAdapter", RailsAiAdmin::Authorization::PunditAdapter.name.demodulize
    assert_equal "Ai", Ai.name
    refute ActiveRecord::Base.connection.tables.any? { |name| name.start_with?("rails_ai_admin_assistant_") }
    get "/operations/tickets"
    assert_response :unauthorized
    refute_includes response.body, "Support task"
  end

  def test_real_devise_session_pundit_scope_and_uuid_update_replay
    login
    get "/operations/tickets"
    assert_response :success
    assert_includes response.body, "Support task"
    refute_includes response.body, "Other tenant task"
    refute_includes response.body, "never exposed"
    token, intent = edit_intent
    2.times do
      patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Reviewed support task", priority: "08" } }
      assert_response :see_other
    end
    assert_equal "Reviewed support task", @ticket.reload.subject
    assert_equal 8, @ticket.priority
    assert_equal 1, @ticket.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    get "/operations/tickets/#{@foreign.id}"
    assert_response :not_found
  end

  def test_reader_fields_and_direct_write_are_denied
    @staff.update!(role: "viewer")
    login
    get "/operations/tickets/#{@ticket.id}"
    assert_response :success
    refute_includes response.body, "restricted note"
    get "/operations/tickets/#{@ticket.id}/edit"
    assert_response :not_found
    get "/operations/tickets", params: { sort: "internal_note" }
    assert_response :unprocessable_content
  end

  def test_revocation_invalidates_an_existing_form
    login
    token, intent = edit_intent
    @staff.update!(role: "viewer", security_version: 2)
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Forbidden update" } }
    assert_response :not_found
    assert_equal "Support task", @ticket.reload.subject
    assert_equal "proposed", RailsAiAdmin::OperationRun.find(intent).status
  end

  def test_tenant_switch_does_not_transfer_an_existing_intent
    login
    token, intent = edit_intent
    get "/"
    post "/tenant", params: { authenticity_token: csrf, tenant_id: @other_tenant.id }
    assert_response :see_other
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Wrong tenant" } }
    assert_response :not_found
    assert_equal "Support task", @ticket.reload.subject
    get "/operations/tickets"
    assert_includes response.body, "Other tenant task"
    refute_includes response.body, "Support task"
    get "/"
    post "/tenant", params: { authenticity_token: csrf, tenant_id: @outsider.id }
    assert_response :not_found
  end

  def test_alias_has_an_independent_scope_and_readonly_guard
    login
    get "/operations/closed_tickets/#{@ticket.id}"
    assert_response :not_found
    @ticket.update!(state: "closed")
    get "/operations/closed_tickets/#{@ticket.id}"
    assert_response :success
    get "/operations/closed_tickets/#{@ticket.id}/edit"
    assert_response :not_found
  end

  def test_csrf_rejection_and_logout_leave_no_write
    login
    token, intent = edit_intent
    patch "/operations/tickets/#{@ticket.id}", params: { intent_ref: intent, record: { subject: "No CSRF" } }
    assert_response :unprocessable_content
    assert_equal "Support task", @ticket.reload.subject
    get "/"
    logout_token = css_select("form[action='/staff_users/sign_out'] input[name=authenticity_token]").first["value"]
    delete "/staff_users/sign_out", params: { authenticity_token: logout_token }
    assert_response :see_other
    get "/operations/tickets"
    assert_response :unauthorized
  end

  def test_host_product_surface_settings_and_ownership_are_preserved
    login
    resolver = RailsToolViews.configuration.scope_resolver
    config = RubyLLM.config
    scope = RailsToolViews::Scope.new(actor: "product:StaffUser:#{@staff.id}", tenant: "product:Tenant:#{@tenant.id}")
    surface = RailsToolViews.present("host_notice", props: { message: "Host product still works" }, scope: scope)
    get "/operations/tickets"
    assert_response :success
    assert_same resolver, RailsToolViews.configuration.scope_resolver
    assert_same config, RubyLLM.config
    refute RailsToolViews.configuration.auto_deliver
    get "/product_surfaces/surfaces/#{surface.id}"
    assert_response :success
    assert_includes response.body, "Host product still works"
    admin_context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: "1")
    error = assert_raises(RailsToolViews::Error) do
      RailsToolViews.restore(surface.id, scope: RailsToolViews::Scope.new(actor: admin_context.actor_ref, tenant: admin_context.tenant_ref))
    end
    assert_equal "NOT_FOUND", error.code
  end

  def test_host_product_chat_is_separate_and_is_not_changed_by_admin_crud
    model = RubyLLM.models.all.find { |entry| entry.provider == "openai" }
    refute_nil model
    chat = ProductChat.create!(model: model)
    message = chat.product_messages.create!(role: "user", content: "Host product message")
    login
    token, intent = edit_intent
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Separate admin operation" } }
    assert_response :see_other
    assert_equal [ message.id ], chat.product_messages.pluck(:id)
    assert_equal "Host product message", message.reload.content
    assert_equal "product_chats", ProductChat.table_name
    refute ActiveRecord::Base.connection.tables.any? { |name| name.start_with?("rails_ai_admin_assistant_") }
  end

  def test_devise_timeout_ends_access_without_reusing_the_admin_context
    login
    token, intent = edit_intent
    travel 31.minutes do
      get "/operations/tickets"
      assert_response :redirect
      # Devise's GET timeout flow redirects to the attempted path after signing
      # out. The next request must resolve an unauthenticated admin context.
      follow_redirect!
      assert_response :unauthorized
      refute_includes response.body, "Support task"
      patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Expired session" } }
      # Devise clears the old session's CSRF state on timeout too.
      assert_response :unprocessable_content
      assert_equal "Support task", @ticket.reload.subject
      assert_equal "proposed", RailsAiAdmin::OperationRun.find(intent).status
    end
  end

  def test_host_policy_matrix_and_field_grants
    anonymous = Struct.new(:request, :session).new(Struct.new(:env).new({}), {})
    assert RailsAiAdmin::TestKit.assert_unauthenticated(adapter: AdminContext.new, controller: anonymous)
    %w[admin operator viewer].each do |role|
      @staff.update!(role: role)
      context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: TicketAdmin, action: :update, record: @ticket, allowed: role != "viewer")
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: TicketAdmin, action: :destroy, record: @ticket, allowed: role == "admin")
      readable = %i[id subject state priority] + (role == "viewer" ? [] : [ :internal_note ])
      writable = role == "viewer" ? [] : %i[subject state priority internal_note]
      assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TicketAdmin, record: @ticket,
        expected: { read: readable, write: writable, search: [ :subject ], sort: [ :priority ] })
    end
    context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
    assert RailsAiAdmin::TestKit.assert_hidden(context: context, resource: TicketAdmin, field: :secret_token)
    assert RailsAiAdmin::TestKit.assert_isolated(context: context, resource: TicketAdmin, foreign_id: @foreign.id)
  end
end
