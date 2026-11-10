require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"
require "webmock/minitest"
require "rails_ai_admin/test_kit"
require "rails_ai_admin/assistant"
WebMock.disable_net_connect!

require_relative "override_render_tracker" if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"
require "rails_ai_admin/templates/inspector" if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"

class SupportHostAcceptanceTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  def setup
    RailsAiAdmin::Assistant::Turn.delete_all
    RailsAiAdmin::Assistant::Chat.find_each(&:destroy!)
    RailsAiAdmin::BatchItem.delete_all
    RailsAiAdmin::WorkItem.delete_all
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::SelectionItem.delete_all
    RailsAiAdmin::Selection.delete_all
    RailsAiAdmin::AuditEvent.delete_all
    SupportTicket.delete_all
    TenantMembership.delete_all
    StaffUser.delete_all
    Tenant.delete_all
    FileUtils.rm_rf(Rails.root.join("tmp/synthetic_deliveries"))
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

  def test_resource_menu_uses_current_pundit_grants_and_stable_registered_links
    login
    get "/operations"
    assert_response :success
    assert_select "nav[aria-label='Admin resources'] h2", text: "Support"
    assert_select "nav a[href='/operations/tickets']", text: "Support queue"
    assert_select "nav a[href='/operations/closed_tickets']", text: "Closed archive"
    assert_select "nav a[href='/operations/tickets'] svg[aria-hidden=true][focusable=false]"
    get "/operations/tickets/#{@ticket.id}"
    assert_select "nav a[href='/operations/tickets'][aria-current=location]"
    @staff.update!(role: "suspended")
    get "/operations"
    assert_response :success
    assert_select ".raa-cards li", count: 0
    refute_includes response.body, "Support queue"
    assert_select "nav[aria-label='Admin resources'] h2", count: 0
    get "/operations/tickets/#{@ticket.id}"
    assert_response :not_found
  end

  def edit_intent
    get "/operations/tickets/#{@ticket.id}/edit"
    assert_response :success
    [ csrf, css_select("input[name=intent_ref]").first["value"] ]
  end

  if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"
    def test_generated_host_template_precedence_and_live_upgrade_diagnostics
      login
      get "/operations/tickets"
      assert_select "[data-raa-override=layout]"
      assert_select "[data-raa-override=resource_index]"
      assert_select "[data-raa-override=field_index]"
      token, intent = edit_intent
      assert_select "[data-raa-override=resource_edit]"
      assert_select "[data-raa-override=resource_form]"
      assert_select "[data-raa-override=field_form]"
      patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "" } }
      assert_response :unprocessable_content
      assert_select "[data-raa-override=resource_edit]"
      assert_select "[data-raa-override=resource_errors]"
      path = "/operations/tickets/#{@ticket.id}/operations/triage"
      get path
      assert_select "[data-raa-override=operation_form]"
      post "#{path}/preflight", params: { authenticity_token: csrf, expected_version: @ticket.lock_version, input: { decision: "triage" } }
      assert_response :success
      assert_select "[data-raa-override=operation_confirmation]"
      assert_equal "open", @ticket.reload.state
      source = Rails.root.join("app/views/rails_ai_admin/resources/edit.html.erb")
      original = source.read
      begin
        source.write(original.sub(/"source_sha256":"[0-9a-f]{64}"/, '"source_sha256":"' + "0" * 64 + '"'))
        check = RailsAiAdmin::Templates::Inspector.new(root: Rails.root).checks.find { |entry| entry.key == "resource_edit" }
        assert_equal :review, check.status
        assert_equal "STALE_SOURCE", check.code
      ensure
        source.write(original)
      end
    end
  end

  def test_packaged_dependencies_and_boot_boundaries
    assert_includes Gem.loaded_specs.fetch("rails_ai_admin").full_gem_path, "/gems/rails_ai_admin-"
    assert_equal "PunditAdapter", RailsAiAdmin::Authorization::PunditAdapter.name.demodulize
    assert_equal "Ai", Ai.name
    # This host opts into admin Chat; its tables are Engine-owned, not product chats.
    assert_equal %w[rails_ai_admin_assistant_chats rails_ai_admin_assistant_messages rails_ai_admin_assistant_turns],
      ActiveRecord::Base.connection.tables.select { |name| name.start_with?("rails_ai_admin_assistant_") }.sort
    get "/operations/tickets"
    assert_response :unauthorized
    refute_includes response.body, "Support task"
    get "/operations/assistant"
    assert_response :unauthorized
  end

  def test_packaged_custom_field_and_fixed_select_validation
    login
    get "/operations/tickets"
    assert_response :success
    refute_includes response.body, "restricted note"
    token, intent = edit_intent
    assert_select ".raa-tab-links a", count: 2
    assert_select "section[hidden]", count: 0
    assert_select "fieldset legend", text: "Classification"
    assert_select "output", text: "open · P0 · restricted note"
    assert_select ".raa-field-help", text: "Use an integer priority."
    assert_select "input[data-custom-field=trimmed_text]"
    assert_select "select[name='record[state]'] option[value=triaged]", text: "Triaged"
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent,
      record: { subject: "  Reviewed task  ", state: "unknown" } }
    assert_response :unprocessable_content
    assert_select "input[data-custom-field=trimmed_text][value='  Reviewed task  ']"
    assert_select "select[name='record[state]'] option[selected][disabled][value=unknown]"
    assert_equal "Support task", @ticket.reload.subject
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: csrf, intent_ref: intent,
      record: { subject: "  Reviewed task  ", state: "triaged" } }
    assert_response :see_other
    assert_equal "Reviewed task", @ticket.reload.subject
    assert_equal "triaged", @ticket.state
    get "/operations/tickets/#{@ticket.id}"
    assert_select "[data-custom-field=trimmed_text]", text: "Reviewed task"
    assert_select "dd", text: "Triaged"
  end

  def test_packaged_computed_dependency_grants_are_not_implicit
    login
    get "/operations/tickets/#{@ticket.id}"
    assert_response :success
    assert_select "dd", text: "open · P0 · restricted note"
    @staff.update!(role: "viewer")
    get "/operations/tickets/#{@ticket.id}"
    assert_response :success
    assert_select "dt", text: "Review summary", count: 0
    refute_includes response.body, "restricted note"
    context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
    assert_includes TicketPolicy.new(context, @ticket).readable_fields, :review_summary
    refute RailsAiAdmin::Authorization::Access.new(context, TicketAdmin).project(@ticket).key?("review_summary")
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
    assert_equal "proposed", RailsAiAdmin::OperationRun.find(RailsAiAdmin::Operations::FormIntent.id_for(intent)).status
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
    assert_equal "rails_ai_admin_assistant_chats", RailsAiAdmin::Assistant::Chat.table_name
    assert_equal 0, RailsAiAdmin::Assistant::Chat.count, "admin CRUD creates no admin conversation"
  end

  # Scripted OpenAI chat-completions responses; RubyLLM's real provider, parser,
  # tool loop and persistence run without network access.
  def stub_admin_llm(script)
    requests = []
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
      requests << JSON.parse(request.body)
      step = script.shift or raise "admin LLM script is empty"
      message = if step[:tool]
        { role: "assistant", content: nil, tool_calls: [ { id: "call_#{SecureRandom.hex(6)}", type: "function", function: { name: step[:tool], arguments: step[:arguments].to_json } } ] }
      else
        { role: "assistant", content: step[:reply] }
      end
      { status: 200, headers: { "Content-Type" => "application/json" }, body: { id: "chatcmpl-host-b", object: "chat.completion", created: Time.now.to_i,
        model: "gpt-4.1-mini", choices: [ { index: 0, message: message, finish_reason: step[:tool] ? "tool_calls" : "stop" } ],
        usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 } }.to_json }
    end
    requests
  end

  def test_admin_chat_proposes_through_the_admin_surface_and_continues_once_beside_the_product_chat
    ENV["SUPPORT_ADMIN_OPENAI_KEY"] = "synthetic-admin-key"
    queue = RailsAiAdmin::AssistantTurnJob.queue_adapter
    RailsAiAdmin::AssistantTurnJob.queue_adapter = ActiveJob::QueueAdapters::TestAdapter.new
    global = RubyLLM.config
    resolver = RailsToolViews.configuration.scope_resolver
    product = ProductChat.create!(model: RubyLLM.models.all.find { |entry| entry.provider == "openai" })
    product_message = product.product_messages.create!(role: "user", content: "Product conversation")
    requests = stub_admin_llm([
      { tool: "search_records", arguments: { resource: "tickets", query: "Support" } },
      { tool: "get_record", arguments: { resource: "tickets", id: @foreign.id.to_s } },
      { tool: "propose_operation", arguments: { resource: "tickets", id: @ticket.id.to_s, operation: "triage", input: { decision: "triage", review_note: "Triaged from chat" } } },
      { reply: "I prepared a triage review. Please confirm it." },
      { reply: "The ticket is triaged." }
    ])
    login
    get "/operations"
    assert_select "nav a[href='/operations/assistant']", text: "Assistant"
    get "/operations/assistant"
    post "/operations/assistant/conversations", params: { authenticity_token: csrf }
    assert_response :see_other
    chat = RailsAiAdmin::Assistant::Chat.find_by!(ref: response.location.split("/").last)
    follow_redirect!
    post "/operations/assistant/conversations/#{chat.ref}/messages", params: { authenticity_token: csrf,
      admission_key: css_select("input[name=admission_key]").first["value"], content: "Triage the support task" }
    assert_response :see_other
    RailsAiAdmin::Assistant::Coordinator.new.run(chat.ref)
    assert_equal "open", @ticket.reload.state, "the assistant never writes business data"
    foreign = JSON.parse(chat.messages.where(role: "tool").order(:id).second.content)
    assert_equal "NOT_FOUND", foreign["error"], "another tenant's ticket is indistinguishable from a missing one"
    refute chat.messages.where(role: "tool").any? { |message| message.content.include?("never exposed") }

    get "/operations/assistant/conversations/#{chat.ref}"
    assert_response :success
    assert_select ".raa-chat-records a[href='/operations/tickets/#{@ticket.id}']", text: "Support task"
    assert_select "section.rails-tool-views-surface dd", text: "Triaged from chat"
    form = css_select("form[action^='/operations/assistant/surfaces/']").first
    assert form, "the conversation renders the admin Surface with its own per-form CSRF token"
    post form["action"], params: form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
    assert_response :see_other
    assert_equal [ "triaged", "Triaged from chat" ], [ @ticket.reload.state, @ticket.internal_note ]
    run = RailsAiAdmin::OperationRun.find_by!(origin: "assistant")
    assert_equal [ "succeeded", 1 ], [ run.status, RailsAiAdmin::WorkItem.count ]
    assert_equal 1, chat.turns.where(kind: "continuation").count
    RailsAiAdmin::Assistant::Coordinator.new.run(chat.ref)
    assert_equal 5, requests.size
    assert_includes requests.last["messages"].reverse.find { |message| message["role"] == "user" }["content"], "Review result"
    get "/operations/assistant/conversations/#{chat.ref}"
    assert_select ".raa-chat-assistant", text: /The ticket is triaged/

    assert_same global, RubyLLM.config
    assert_equal "gpt-5.6-luna", RubyLLM.config.default_model
    assert_nil RubyLLM.config.openai_api_key, "the admin key never enters global RubyLLM settings"
    assert_same resolver, RailsToolViews.configuration.scope_resolver
    refute RailsToolViews.configuration.auto_deliver
    assert_equal [ product_message.id ], product.product_messages.reload.pluck(:id)
    assert_empty product.ruby_llm_usages.reload
    assert chat.ruby_llm_usages.reload.any? && chat.ruby_llm_usages.all? { |usage| usage.owner == chat }
  ensure
    ENV.delete("SUPPORT_ADMIN_OPENAI_KEY")
    RailsAiAdmin::AssistantTurnJob.queue_adapter = queue if queue
  end

  def test_unicode_list_state_and_current_sort_survive_packaged_recovery_and_save
    login
    @ticket.update!(subject: "客户 🚀 task")
    state = { "q" => "客户 🚀", "sort" => "priority", "direction" => "desc" }
    get "/operations/tickets", params: state
    assert_response :success
    assert_select "th[aria-sort=descending] a", text: "Priority"
    view = css_select("main a").find { |node| node.text.start_with?("View ") }
    assert_equal state, Rack::Utils.parse_nested_query(URI(view["href"]).query)["return_to"]
    get view["href"]
    get css_select("main a").find { |node| node.text == "Edit" }["href"]
    assert_response :success
    ref = css_select("input[name=intent_ref]").first["value"]
    form = css_select("form[data-raa-form-recovery-return-state-value]").first
    assert_nil URI(form["action"]).query
    encoded = form["data-raa-form-recovery-return-state-value"]
    assert encoded.ascii_only?
    get "/operations/tickets/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref, "X-RailsAiAdmin-Return-State" => encoded }
    assert_response :success
    assert_select "input[name='return_to[q]'][value='客户 🚀']"
    patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: csrf, intent_ref: ref, return_to: state, record: { subject: "Saved outside original search" } }
    assert_response :see_other
    assert_equal state, Rack::Utils.parse_nested_query(URI(response.location).query)["return_to"]
    follow_redirect!
    back = css_select("main a").find { |node| node.text == "Tickets" }
    assert_equal state, Rack::Utils.parse_nested_query(URI(back["href"]).query)
    assert_equal "Saved outside original search", @ticket.reload.subject
  end

  def test_devise_timeout_recovery_renews_only_the_original_unconsumed_intent
    login
    token, intent = edit_intent
    travel 31.minutes do
      get "/operations/tickets"
      assert_response :redirect
      follow_redirect!
      assert_response :unauthorized
      patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: token, intent_ref: intent, record: { subject: "Not yet saved" } }
      assert_response :unprocessable_content
      assert_equal "session", response.headers["X-RailsAiAdmin-Form-Recovery"]
      assert_equal "Support task", @ticket.reload.subject
      login
      get "/operations/tickets/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => intent }
      assert_response :success
      assert_equal "ready", response.headers["X-RailsAiAdmin-Form-Recovery"]
      assert_select "input[name=intent_ref][value='#{intent}']"
      assert_select "a[href='/staff_users/sign_in'][target=_blank]"
      assert_equal 1, RailsAiAdmin::OperationRun.count
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
      patch "/operations/tickets/#{@ticket.id}", params: { authenticity_token: csrf, intent_ref: intent, record: { subject: "Explicit recovery after Devise timeout" } }
      assert_response :see_other
      assert_equal "Explicit recovery after Devise timeout", @ticket.reload.subject
      assert_equal 1, @ticket.lock_version
      get "/operations/tickets/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => intent }
      assert_response :not_found
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
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
      # The rejected request never consumed the form: no run is past proposed.
      refute RailsAiAdmin::OperationRun.where(id: RailsAiAdmin::Operations::FormIntent.id_for(intent)).where.not(status: "proposed").exists?
    end
  end

  def test_pundit_named_scopes_follow_role_grants_and_tenant_scope
    @ticket.update!(state: "triaged")
    SupportTicket.create!(tenant: @tenant, subject: "Support open without note")
    SupportTicket.create!(tenant: @other_tenant, subject: "Support foreign open")
    login
    get "/operations/tickets", params: { q: "Support" }
    assert_response :success
    assert_equal [ "Open", "Triaged", "Missing internal note" ], css_select("nav.raa-scopes a").map(&:text)
    assert_select "nav.raa-scopes a[aria-current]", count: 0
    assert_includes response.body, "Support task"
    assert_includes response.body, "Support open without note"
    get "/operations/tickets", params: { q: "Support", scope: "open" }
    assert_select "nav.raa-scopes a[aria-current=true]", text: "Open"
    assert_includes response.body, "Support open without note"
    refute_includes response.body, "Support task"
    refute_includes response.body, "Support foreign open"
    get "/operations/tickets", params: { scope: "missing_note" }
    assert_includes response.body, "Support open without note"
    refute_includes response.body, "Support task"
    @staff.update!(role: "viewer")
    get "/operations/tickets", params: { scope: "missing_note" }
    assert_response :see_other
    follow_redirect!
    assert_select ".raa-notice", text: /Some list settings/
    assert_equal [ "Open", "Triaged" ], css_select("nav.raa-scopes a").map(&:text)
    %w[admin operator viewer].each do |role|
      @staff.update!(role: role)
      context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
      expected = %w[open triaged] + (role == "viewer" ? [] : [ "missing_note" ])
      assert RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: TicketAdmin, expected: expected)
      assert RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: ClosedTicketAdmin, expected: [])
    end
  end

  def test_pundit_filters_follow_role_grants_and_tenant_scope
    @ticket.update!(state: "triaged", priority: 2)
    SupportTicket.create!(tenant: @tenant, subject: "Support urgent", state: "open", priority: 1)
    SupportTicket.create!(tenant: @tenant, subject: "Support later", state: "open", priority: 9)
    SupportTicket.create!(tenant: @other_tenant, subject: "Support foreign urgent", state: "open", priority: 1)
    login
    get "/operations/tickets", params: { q: "Support", filter: { state: { eq: "open" }, priority: { lte: "3" } } }
    assert_response :success
    assert_select "select[name='filter[state][eq]'] option[selected][value=open]", text: "Open"
    assert_select "input[type=number][name='filter[priority][lte]'][value='3']"
    assert_includes response.body, "Support urgent"
    [ "Support later", "Support task", "Support foreign urgent" ].each { |subject| refute_includes response.body, subject }
    @staff.update!(role: "viewer")
    get "/operations/tickets", params: { filter: { state: { eq: "open" }, priority: { lte: "3" } } }
    assert_response :see_other
    assert_equal({ "filter" => { "state" => { "eq" => "open" } } }, Rack::Utils.parse_nested_query(URI(response.location).query))
    follow_redirect!
    assert_includes response.body, "Support later"
    assert_select "input[name='filter[priority][lte]']", count: 0
  end

  def test_ticket_index_settings_order_columns_by_priority_and_count_within_tenant
    @ticket.update!(priority: 5)
    SupportTicket.create!(tenant: @tenant, subject: "Urgent index", priority: 1)
    SupportTicket.create!(tenant: @other_tenant, subject: "Foreign index", priority: 0)
    login
    get "/operations/tickets"
    assert_response :success
    # review_summary is a declared column, but it depends on internal_note, which
    # the index presentation mask hides, so the column cannot be computed there.
    assert_equal [ "Select", "Subject", "State", "Priority", "Actions" ], css_select("thead th").map { |node| node.text.strip }
    assert_select "th[aria-sort=ascending] a", text: "Priority"
    assert_select "p.raa-count", text: "2 matching records"
    assert_includes css_select("tbody tr").first.text, "Urgent index"
    refute_includes response.body, "Foreign index"
  end

  def test_host_policy_matrix_and_field_grants
    anonymous = Struct.new(:request, :session).new(Struct.new(:env).new({}), {})
    assert RailsAiAdmin::TestKit.assert_unauthenticated(adapter: AdminContext.new, controller: anonymous)
    %w[admin operator viewer].each do |role|
      @staff.update!(role: role)
      context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: TicketAdmin, action: :update, record: @ticket, allowed: role != "viewer")
      assert RailsAiAdmin::TestKit.assert_access(context: context, resource: TicketAdmin, action: :destroy, record: @ticket, allowed: role == "admin")
      readable = %i[id subject state priority] + (role == "viewer" ? [] : %i[internal_note review_summary])
      writable = role == "viewer" ? [] : %i[subject state priority internal_note]
      assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TicketAdmin, record: @ticket,
        expected: { read: readable, write: writable, search: [ :subject ], sort: [ :priority ], filter: role == "viewer" ? [ :state ] : %i[state priority] })
    end
    context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
    assert RailsAiAdmin::TestKit.assert_hidden(context: context, resource: TicketAdmin, field: :secret_token)
    assert RailsAiAdmin::TestKit.assert_isolated(context: context, resource: TicketAdmin, foreign_id: @foreign.id)
  end

  def test_admin_surface_confirms_the_native_triage_intent_and_coexists_with_the_product_surface
    resolver = RailsToolViews.configuration.scope_resolver
    login
    path = "/operations/tickets/#{@ticket.id}/operations/triage"
    get path
    post "#{path}/preflight", params: { authenticity_token: csrf, expected_version: @ticket.lock_version, input: { decision: "triage", review_note: "Surface review" } }
    assert_response :success
    surface_form = css_select("form.raa-surface-review[action='#{path}/surface']").first
    assert surface_form, "a separate form carries its own per-form CSRF token"
    confirmation = { authenticity_token: csrf, intent_ref: css_select("input[name=intent_ref]").first["value"],
      confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
    post "#{path}/surface", params: surface_form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
    assert_response :see_other
    surface_id = response.location[%r{/operations/assistant/surfaces/([0-9a-f-]{36})\z}, 1]
    assert surface_id
    follow_redirect!
    assert_response :success
    assert_select "section.rails-tool-views-surface h2", text: "Review and triage ticket"
    assert_select "dd", text: "Surface review"
    form = css_select("form[action='/operations/assistant/surfaces/#{surface_id}/actions']").first
    assert form, "the admin endpoint, not the product mount, receives admin actions"
    fields = form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }

    get "/product_surfaces/surfaces/#{surface_id}"
    assert_response :not_found, "the product resolver's scope cannot restore an admin Surface"
    admin_scope = RailsToolViews::Scope.new(actor: "raa:actor:StaffUser:#{@staff.id}", tenant: "raa:tenant:Tenant:#{@tenant.id}")
    error = assert_raises(RailsToolViews::Error) { RailsToolViews.restore(surface_id, scope: admin_scope) }
    assert_equal "NOT_ALLOWED", error.code, "an admin-shaped scope outside admin endpoints is denied"

    post "/operations/assistant/surfaces/#{surface_id}/actions", params: fields
    assert_response :see_other
    follow_redirect!
    assert_select "p[role=status]", text: "Operation completed."
    refute_includes response.body, "cannot be rendered", "the completed review renders after the triage grant lapses"
    assert_select "dd", text: "Surface review"
    assert_equal [ "triaged", "Surface review", 1 ], [ @ticket.reload.state, @ticket.internal_note, @ticket.lock_version ]
    assert_equal [ "surface" ], RailsAiAdmin::AuditEvent.where(correlation_ref: confirmation[:intent_ref], status: "succeeded").pluck(:origin)
    post "#{path}/execute", params: confirmation
    assert_response :see_other, "the native page replays the intent the Surface committed"
    assert_equal 1, RailsAiAdmin::WorkItem.count
    assert_equal 1, @ticket.reload.lock_version

    product = RailsToolViews.present("host_notice", props: { message: "Product still separate" },
      scope: RailsToolViews::Scope.new(actor: "product:StaffUser:#{@staff.id}", tenant: "product:Tenant:#{@tenant.id}"))
    get "/product_surfaces/surfaces/#{product.id}"
    assert_response :success
    assert_includes response.body, "Product still separate"
    get "/operations/assistant/surfaces/#{product.id}"
    assert_response :not_found, "admin endpoints cannot open product Surfaces"
    assert_same resolver, RailsToolViews.configuration.scope_resolver
    refute RailsToolViews.configuration.auto_deliver
    assert RailsToolViews.registry.fetch("host_notice")
  end

  def test_offline_ruby_llm_assistant_proposes_triage_and_only_the_staff_member_confirms
    require "rails_ai_admin/integrations/propose_operation"
    product_config = RubyLLM.config
    product_model = RubyLLM.config.default_model
    chat = ProductChat.create!
    chat.product_messages.create!(role: "user", content: "Product conversation")
    context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
    tool = RailsAiAdmin::Integrations::ProposeOperation.new(context: context, conversation: "raa:conversation:triage-1")
    arguments = { resource: "tickets", record: @ticket.id, operation: "triage", input: { decision: "close", review_note: "Duplicate of an earlier report" } }
    turns = [
      { id: "c1", object: "chat.completion", model: "gpt-4.1-mini", choices: [ { index: 0, finish_reason: "tool_calls", message: { role: "assistant", content: nil,
        tool_calls: [ { id: "call_triage_1", type: "function", function: { name: "raa_propose_operation", arguments: arguments.to_json } } ] } } ] },
      { id: "c2", object: "chat.completion", model: "gpt-4.1-mini", choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: "Please confirm the closing review." } } ] }
    ]
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(*turns.map { |turn| { status: 200, headers: { "Content-Type" => "application/json" }, body: turn.to_json } })
    answer = RubyLLM.context { |config| config.openai_api_key = "synthetic-offline-key" }
      .chat(model: "gpt-4.1-mini", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
      .with_tools(tool).ask("Close this duplicate ticket.")
    assert_equal "Please confirm the closing review.", answer.content
    assert_equal "open", @ticket.reload.state, "the assistant's turn never writes"
    run = RailsAiAdmin::OperationRun.find_by!(origin: "assistant")
    # Surfaces persist across this suite's two passes; scope to this run's actor.
    surface = RailsToolViews::Surface.find_by!(context_ref: "raa:conversation:triage-1", actor_ref: "raa:actor:StaffUser:#{@staff.id}")
    assert_equal [ "proposed", run.id ], [ run.status, surface.props["intent"] ]
    assert_same product_config, RubyLLM.config
    assert_equal product_model, RubyLLM.config.default_model
    assert_equal [ "Product conversation" ], chat.product_messages.pluck(:content)

    login
    get "/operations/assistant/surfaces/#{surface.id}"
    assert_response :success
    assert_select "p", text: /An assistant proposed this/
    assert_select "dd", text: "Duplicate of an earlier report"
    form = css_select("form[action='/operations/assistant/surfaces/#{surface.id}/actions']").first
    post form["action"], params: form.css("input[type=hidden]").to_h { |node| [ node["name"], node["value"] ] }
    assert_response :see_other
    assert_equal [ "closed", "Duplicate of an earlier report" ], [ @ticket.reload.state, @ticket.internal_note ]
    assert_equal [ "surface" ], RailsAiAdmin::AuditEvent.where(correlation_ref: run.id, status: "succeeded").pluck(:origin)
    assert_equal "reviewed", tool.call(**arguments, tool_call: RubyLLM::ToolCall.new(id: "call_triage_1", name: tool.name, arguments: arguments.stringify_keys))[:status]
    assert_equal 1, RailsAiAdmin::WorkItem.where(operation_run_id: run.id).count
  end

  def test_custom_operation_confirmation_postcondition_replay_and_outbox
    login
    path = "/operations/tickets/#{@ticket.id}/operations/triage"
    get path
    assert_response :success
    post "#{path}/preflight", params: { authenticity_token: csrf, expected_version: @ticket.lock_version,
      input: { decision: "triage", review_note: "<script>reviewed privately</script>" } }
    assert_response :success
    refute_includes response.body, "<script>reviewed privately</script>"
    assert_includes response.body, "&lt;script&gt;"
    assert_equal "open", @ticket.reload.state
    confirmation = { authenticity_token: csrf, intent_ref: css_select("input[name=intent_ref]").first["value"],
      confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
    2.times do
      post "#{path}/execute", params: confirmation
      assert_response :see_other
    end
    assert_equal "triaged", @ticket.reload.state
    assert_equal 1, @ticket.lock_version
    assert_equal 1, RailsAiAdmin::WorkItem.count
    item = RailsAiAdmin::WorkItem.first
    assert_equal "pending", item.status
    assert RailsAiAdmin::Outbox::Dispatcher.new.run(item.id).success?
    assert_equal "succeeded", item.reload.status
    receipt = JSON.parse(Rails.root.join("tmp/synthetic_deliveries/#{item.id}.json").read)
    assert_equal "raa:tenant:Tenant:#{@tenant.id}", receipt.fetch("tenant_ref")
    refute_includes receipt.to_json, "reviewed privately"
    assert RailsAiAdmin::Outbox::Dispatcher.new.run(item.id).success?
    assert_equal 1, Rails.root.join("tmp/synthetic_deliveries/applications.log").readlines.size
    assert_equal 1, Rails.root.join("tmp/synthetic_deliveries/requests.log").readlines.size
  end

  def test_queued_work_rechecks_real_membership_epoch_and_separates_business_success
    context = RailsAiAdmin::Context.new(actor: @staff, tenant: @tenant, security_version: @staff.security_version.to_s)
    runner = RailsAiAdmin::Operations::Runner.new
    proposal = runner.preflight(context: context, resource: TicketAdmin, operation: :triage,
      target_id: @ticket.id, expected_version: @ticket.lock_version, input: { decision: "triage" })
    result = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
    assert result.success?
    @staff.update!(role: "viewer", security_version: 2)
    delivery = RailsAiAdmin::Outbox::Dispatcher.new.run(result.work_refs.first)
    assert_equal "cancelled", delivery.status
    assert_equal "triaged", @ticket.reload.state
    assert_equal "succeeded", proposal.intent.reload.status
    assert_empty Dir[Rails.root.join("tmp/synthetic_deliveries/*.json")]
  end

  def test_reused_delivery_worker_rebuilds_real_tenant_context
    results = [ [ @tenant, @ticket ], [ @other_tenant, @foreign ] ].map do |tenant, ticket|
      context = RailsAiAdmin::Context.new(actor: @staff, tenant: tenant, security_version: @staff.security_version.to_s)
      runner = RailsAiAdmin::Operations::Runner.new
      proposal = runner.preflight(context: context, resource: TicketAdmin, operation: :triage,
        target_id: ticket.id, expected_version: ticket.lock_version, input: { decision: "triage" })
      runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
    end
    worker = RailsAiAdmin::Outbox::Dispatcher.new
    results.each { |result| assert worker.run(result.work_refs.first).success? }
    refs = results.map { |result| JSON.parse(Rails.root.join("tmp/synthetic_deliveries/#{result.work_refs.first}.json").read).fetch("tenant_ref") }
    assert_equal [ "raa:tenant:Tenant:#{@tenant.id}", "raa:tenant:Tenant:#{@other_tenant.id}" ], refs
    assert SupportTicket.create!(tenant: @tenant, subject: "Writes remain available after delivery").persisted?
  end
  def test_uuid_selection_uses_independent_pundit_grant_and_fresh_tenant
    login
    get "/operations/tickets"
    token = css_select("form#raa-selection input[name=authenticity_token]").first["value"]
    post "/operations/tickets/selections", params: { authenticity_token: token, target_ids: [ @ticket.id ] }
    assert_response :see_other
    path = URI(response.location).path
    get path
    assert_response :success
    assert_includes response.body, "Support task"
    assert_includes response.body, @ticket.id
    assert_equal @ticket.id, RailsAiAdmin::SelectionItem.first.target_id
    assert_equal 0, RailsAiAdmin::OperationRun.count
    @staff.update!(role: "viewer")
    get path
    assert_response :not_found
    refute_includes response.body, "Support task"
  end
  def test_packaged_uuid_collection_admission_partial_cancel_and_outbox_are_distinct
    second = SupportTicket.create!(tenant: @tenant, subject: "Second selected ticket")
    login
    get "/operations/tickets"
    token = css_select("form#raa-selection input[name=authenticity_token]").first["value"]
    post "/operations/tickets/selections", params: { authenticity_token: token, target_ids: [ @ticket.id, second.id ] }
    assert_response :see_other
    get URI(response.location).path
    ref = RailsAiAdmin::Selection.first.id
    path = "/operations/tickets/operations/bulk_triage"
    get path, params: { selection_ref: ref }
    token = csrf
    post "#{path}/preflight", params: { authenticity_token: token, selection_ref: ref, input: { decision: "triage", review_note: "Private batch note" } }
    assert_response :success
    confirmation = { authenticity_token: csrf, intent_ref: css_select("input[name=intent_ref]").first["value"],
      selection_ref: ref, confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
    post "#{path}/execute", params: confirmation
    assert_response :see_other
    job_path = URI(response.location).path
    get job_path
    assert_response :success
    refute_includes response.body, "Private batch note"
    assert_equal 0, RailsAiAdmin::WorkItem.count
    RailsAiAdmin::Collections::Dispatcher.new.run(confirmation[:intent_ref], limit: 1)
    get job_path
    token = css_select("form[action='#{job_path}/cancel'] input[name=authenticity_token]").first["value"]
    post "#{job_path}/cancel", params: { authenticity_token: token }
    assert_response :see_other
    get job_path
    assert_response :success
    assert_includes response.body, "Partially succeeded"
    assert_equal 1, SupportTicket.where(id: [ @ticket.id, second.id ], state: "triaged").count
    assert_equal 1, RailsAiAdmin::WorkItem.where(status: "pending").count
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    child = RailsAiAdmin::OperationRun.where(parent_run_id: confirmation[:intent_ref], status: "succeeded").first
    assert_nil child.confirmed_at
    post "#{path}/execute", params: confirmation
    assert_response :see_other
    assert_equal 2, RailsAiAdmin::BatchItem.count
  end
end
