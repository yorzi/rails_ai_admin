# frozen_string_literal: true

require "test_helper"
require "support/assistant"
require "rails_ai_admin/mcp"

# propose_bulk_change: one review for many records. Only the person's
# confirmation writes, one native update per record, as that person.
class AssistantBulkChangesIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  class BulkCustomerAdmin < RailsAiAdmin::Resource
    model "Customer"
    key :changeable_customers
    title :name
    fields do
      id :id
      text :name, searchable: :contains
      integer :points, filterable: true
      boolean :active, filterable: true
    end
    assistant_changes :update, :bulk_update
  end

  class SingleCustomerAdmin < RailsAiAdmin::Resource
    model "Customer"
    key :contract_customers
    title :name
    fields do
      id :id
      text :name
      integer :points
    end
    assistant_changes :update
  end

  class Policy < AssistantPolicy
    class_attribute :selectable, default: true
    class_attribute :locked_names, default: []
    class_attribute :join_duplicates, default: false

    def select_records?(context:, resource:) = selectable
    def allowed?(context:, action:, resource:, record: nil)
      return false if action.to_sym == :update && record && locked_names.include?(record.name)
      super
    end

    def scope(...)
      scoped = super
      join_duplicates ? scoped.joins("INNER JOIN customers copies ON copies.account_id = customers.account_id") : scoped
    end
  end

  RESOURCES = %w[AssistantBulkChangesIntegrationTest::BulkCustomerAdmin AssistantBulkChangesIntegrationTest::SingleCustomerAdmin].freeze

  def setup
    reset_database
    reset_assistant
    Policy.selectable = true
    Policy.locked_names = []
    Policy.join_duplicates = false
    TestPolicy.granted_filters = %i[points active]
    @bob = Customer.create!(account_id: 1, name: "Bob", points: 4)
    @cara = Customer.create!(account_id: 1, name: "Cara", points: 9)
    post "/test/sign_in/1"
  end

  def teardown
    RailsToolViews.reset_registry!
  end

  def with_bulk(&block) = with_assistant(resources: RESOURCES, policy: "AssistantBulkChangesIntegrationTest::Policy", &block)

  def start_chat
    post "/backoffice/assistant/conversations"
    RailsAiAdmin::Assistant::Chat.find_by!(ref: response.location[%r{conversations/([0-9a-f-]{36})\z}, 1])
  end

  def propose(chat, arguments, reply: "Please review it.")
    admit(chat, "Bulk change")
    LLMFixture.tool("propose_bulk_change", arguments)
    LLMFixture.reply(reply)
    drain(chat)
    JSON.parse(chat.messages.where(role: "tool").order(:id).last.content)
  end

  def review_link(chat)
    get "/backoffice/assistant/conversations/#{chat.ref}"
    css_select(".raa-chat-bulk a").first["href"]
  end

  def decide(decision)
    form = css_select("form[action$='/bulk_change']").first
    post form["action"], params: browser_fields(form).merge("decision" => decision)
  end

  def test_confirmation_does_not_add_records_that_became_writable_after_review
    with_bulk do
      Policy.locked_names = [ "Cara" ]
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      get review_link(chat)
      assert_select "tbody tr", count: 1

      Policy.locked_names = []
      decide("confirm")
      assert_response :conflict
      assert_equal [ 4, 9 ], [ @bob.reload.points, @cara.reload.points ]
      assert_empty RailsAiAdmin::OperationRun.all
    end
  end

  def test_confirmation_can_only_be_used_once_even_when_the_update_is_a_no_op
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: @bob.points }, ids: [ @bob.id.to_s ] })
      get review_link(chat)
      form = css_select("form[action$='/bulk_change']").first
      fields = browser_fields(form)
      post form["action"], params: fields.merge("decision" => "confirm")
      assert_response :success
      assert_equal @bob.lock_version, Customer.find(@bob.id).lock_version
      post form["action"], params: fields.merge("decision" => "confirm")
      assert_response :conflict
      assert_equal 1, RailsAiAdmin::AuditEvent.where(operation: "update", status: "succeeded").count
    end
  end

  def test_one_review_updates_each_record_as_the_person_and_tells_the_chat_once
    with_bulk do
      chat = start_chat
      # Alice has 0 points, so the filter selects Bob and Cara.
      result = propose(chat, { resource: "changeable_customers", values: { points: 0 }, filters: { points: { gte: "1" } } })
      assert_equal [ "awaiting_human_confirmation", 2, 0 ], result.values_at("status", "records", "skipped")
      assert_equal [ 0, 4, 9 ], Customer.where(account_id: 1).order(:id).pluck(:points), "the proposal changes nothing"
      runs, audits = RailsAiAdmin::OperationRun.count, RailsAiAdmin::AuditEvent.count

      link = review_link(chat)
      assert_select ".raa-chat-bulk h2", text: "A change to 2 records in Changeable customers"
      assert_select ".raa-chat-activity", text: "Prepared one review for several records in Changeable customers"
      refute_includes link, "points", "values travel only inside the encrypted token"
      get link
      assert_response :success
      assert_select "h1", text: "Review a change to Changeable customers"
      assert_select "tbody tr", count: 2
      assert_select "tbody tr", text: /Bob\s+4 → 0/
      assert_select "form[action$='/bulk_change'][data-turbo=false]", 1, "the 200 result page must not be dropped by Turbo"
      assert_equal [ runs, audits ], [ RailsAiAdmin::OperationRun.count, RailsAiAdmin::AuditEvent.count ], "showing the review writes nothing"

      decide("confirm")
      assert_response :success
      assert_select "[role=status]", text: "Updated 2 records."
      assert_equal [ 0, 0, 0 ], Customer.where(account_id: 1).order(:id).pluck(:points)
      updates = RailsAiAdmin::OperationRun.where(operation: "update", status: "succeeded")
      assert_equal 2, updates.count
      assert updates.all? { |run| run.origin == "assistant" && run.approved_by_ref == context.actor_ref }
      assert_equal 2, RailsAiAdmin::AuditEvent.where(operation: "update", status: "succeeded").count
      continuation = chat.turns.find_by!(kind: "continuation")
      assert_equal "Review result: the user confirmed \"update points on 2 changeable customers\". 2 of 2 records were updated.", continuation.content

      get link
      assert_response :conflict, "the review is out of date once its records changed"
      post link.split("?").first, params: { change: Rack::Utils.parse_query(URI(link).query)["change"], decision: "confirm" }
      assert_response :conflict
      assert_equal 2, updates.count
      assert_equal 1, chat.turns.where(kind: "continuation").count
    end
  end

  def test_records_the_person_cannot_update_are_listed_and_skipped
    with_bulk do
      Policy.locked_names = [ "Cara" ]
      chat = start_chat
      result = propose(chat, { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      assert_equal [ 1, 1 ], result.values_at("records", "skipped")
      get review_link(chat)
      assert_select "tbody tr", count: 1
      assert_select "h2", text: "1 selected record will not be changed"
      decide("confirm")
      assert_equal [ 1, 9 ], [ @bob.reload.points, @cara.reload.points ]
      assert_select "tbody tr", text: /Cara/
      assert_includes chat.turns.find_by!(kind: "continuation").content, "1 of 2 records were updated."
    end
  end

  def test_submission_requires_an_explicit_decision
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { name: "Same" }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      get review_link(chat)
      decide(nil)
      assert_response :unprocessable_content
      assert_equal %w[Bob Cara], [ @bob.reload.name, @cara.reload.name ]
    end
  end

  def test_dismissing_changes_nothing_and_a_changed_record_makes_the_review_a_conflict
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { name: "Same" }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      link = review_link(chat)
      get link
      decide("dismiss")
      assert_redirected_to "/backoffice/assistant/conversations/#{chat.ref}"
      assert_equal %w[Bob Cara], [ @bob.reload.name, @cara.reload.name ]
      assert_includes chat.turns.find_by!(kind: "continuation").content, "the user dismissed"
      path, query = link.split("?")
      get link
      assert_response :conflict
      post path, params: { change: Rack::Utils.parse_query(query).fetch("change"), decision: "confirm" }
      assert_response :conflict
      assert_equal %w[Bob Cara], [ @bob.reload.name, @cara.reload.name ]

      other = start_chat
      propose(other, { resource: "changeable_customers", values: { name: "Same" }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      link = review_link(other)
      @cara.update!(points: 50)
      get link
      assert_response :conflict
      assert_equal %w[Bob Cara], [ @bob.reload.name, @cara.reload.name ]
      # Even when a selected record changed, the user can still dismiss the stale review.
      path, query = link.split("?")
      post path, params: { change: Rack::Utils.parse_query(query).fetch("change"), decision: "dismiss" }
      assert_redirected_to "/backoffice/assistant/conversations/#{other.ref}"
      assert_equal %w[Bob Cara], [ @bob.reload.name, @cara.reload.name ]
    end
  end

  def test_joined_policy_counts_distinct_records_before_enforcing_the_cap
    with_bulk do
      Policy.join_duplicates = true
      Customer.insert_all!(Array.new(101) { { name: "Fixture", account_id: 1 } })
      chat = start_chat
      result = propose(chat, { resource: "changeable_customers", values: { points: 1 }, filters: { points: { gte: "1" } } })
      assert_equal [ "awaiting_human_confirmation", 2 ], result.values_at("status", "records")
      get review_link(chat)
      assert_select "tbody tr", count: 2
      decide("confirm")
      assert_equal [ 1, 1 ], [ @bob.reload.points, @cara.reload.points ]
      assert_equal 2, RailsAiAdmin::AuditEvent.where(operation: "update", status: "succeeded").count
    end
  end

  def test_tokens_are_bound_to_the_person_the_selection_and_its_lifetime
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: 2 }, ids: [ @bob.id.to_s ] })
      link = review_link(chat)
      path, query = link.split("?")
      token = Rack::Utils.parse_query(query)["change"]
      get "#{path}?#{{ change: "#{token[0..-3]}xx" }.to_query}"
      assert_response :not_found
      get "/backoffice/selections/#{SecureRandom.uuid}/bulk_change?#{{ change: token }.to_query}"
      assert_response :not_found
      post "/test/sign_in/2"
      get link
      assert_response :not_found
      post "/test/sign_in/1"
      travel(RailsAiAdmin.configuration.intent_ttl + 1.minute) do
        get link
        assert_response :not_found
      end
      get link
      assert_response :success
      assert_equal 4, @bob.reload.points
    end
  end

  def test_the_tool_needs_the_declaration_the_selection_grant_and_valid_bounded_targets
    with_bulk do
      chat = start_chat
      [ [ { resource: "contract_customers", values: { points: 1 }, ids: [ @bob.id.to_s ] },
          { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s ], query: "Bob" },
          { resource: "changeable_customers", values: { points: "many" }, ids: [ @bob.id.to_s ] } ],
        [ { resource: "changeable_customers", values: { secret: "x" }, ids: [ @bob.id.to_s ] },
          { resource: "changeable_customers", values: { points: 1 }, ids: [ @other.id.to_s ] },
          { resource: "changeable_customers", values: { points: 1 }, query: "Nobody" } ] ].each do |calls|
        admit(chat, "Try bulk changes")
        calls.each { |arguments| LLMFixture.tool("propose_bulk_change", arguments) }
        LLMFixture.reply("Done.")
        drain(chat)
      end
      errors = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content)["error"] }
      assert_equal %w[NOT_FOUND INVALID_QUERY VALIDATION_FAILED VALIDATION_FAILED NOT_FOUND NOT_FOUND], errors

      101.times { |index| Customer.create!(account_id: 1, name: "Many #{index}", points: 1) }
      admit(chat, "Everyone")
      LLMFixture.tool("propose_bulk_change", { resource: "changeable_customers", values: { points: 0 } })
      LLMFixture.reply("Too many.")
      drain(chat)
      assert_equal "completed", chat.turns.reorder(:sequence).last.status, chat.turns.reorder(:sequence).last.error_code.inspect
      assert_equal "TOO_MANY", JSON.parse(chat.messages.where(role: "tool").order(:id).last.content)["error"]

      Policy.selectable = false
      admit(chat, "Again")
      LLMFixture.tool("propose_bulk_change", { resource: "changeable_customers", values: { points: 0 }, ids: [ @bob.id.to_s ] })
      LLMFixture.reply("No.")
      drain(chat)
      assert_equal "NOT_FOUND", JSON.parse(chat.messages.where(role: "tool").order(:id).last.content)["error"]
      assert_equal 0, RailsAiAdmin::OperationRun.count
    end
  end

  def test_describe_resource_lists_bulk_update_only_when_declared_and_granted
    with_bulk do
      chat = start_chat
      admit(chat, "Describe")
      LLMFixture.tool("describe_resource", { resource: "changeable_customers" })
      LLMFixture.tool("describe_resource", { resource: "contract_customers" })
      LLMFixture.reply("Done.")
      drain(chat)
      bulk, single = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content)["changes"] }
      entry = bulk.find { |change| change["action"] == "bulk_update" }
      assert_equal [ %w[name points active], 100 ], [ entry["fields"].map { |field| field["name"] }, entry["max_records"] ]
      assert_equal [ "update" ], single.map { |change| change["action"] }
      tools = LLMFixture.requests.first["tools"].map { |tool| tool.dig("function", "name") }
      assert_includes tools, "propose_bulk_change"
    end
    with_assistant do
      admit(new_chat, "Hello")
      LLMFixture.reply("Hi.")
      drain(RailsAiAdmin::Assistant::Chat.last)
      refute_includes LLMFixture.requests.last["tools"].map { |tool| tool.dig("function", "name") }, "propose_bulk_change",
        "no tool without a resource that declares bulk_update"
    end
  end

  def test_one_reply_prepares_at_most_three_single_reviews
    with_bulk do
      chat = start_chat
      admit(chat, "Zero everyone, one by one")
      4.times { |index| LLMFixture.tool("propose_change", { resource: "changeable_customers", action: "update", id: @bob.id.to_s, values: { points: index } }) }
      LLMFixture.reply("I prepared three reviews.")
      drain(chat)
      results = chat.messages.where(role: "tool").order(:id).map { |message| JSON.parse(message.content) }
      assert_equal [ "awaiting_human_confirmation" ] * 3, results.first(3).map { |result| result["status"] }
      assert_equal "LIMIT_REACHED", results.last["error"]
      assert_equal 3, RailsAiAdmin::OperationRun.where(origin: "assistant").count
      admit(chat, "Next one")
      LLMFixture.tool("propose_change", { resource: "changeable_customers", action: "update", id: @cara.id.to_s, values: { points: 1 } })
      LLMFixture.reply("Another review.")
      drain(chat)
      assert_equal "awaiting_human_confirmation", JSON.parse(chat.messages.where(role: "tool").order(:id).last.content)["status"], "each reply has its own allowance"
    end
  end

  def test_mcp_returns_a_review_url_instead_of_the_token
    with_bulk do
      token = RailsAiAdmin::Mcp::AccessToken.issue!(context, name: "Agent", lifetime: "30").last
      post "/backoffice/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "propose_bulk_change", arguments: { resource: "changeable_customers", values: { points: 3 }, ids: [ @bob.id.to_s ] } } }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
      result = JSON.parse(response.body).dig("result", "structuredContent")
      assert_equal "awaiting_human_confirmation", result["status"]
      refute result.key?("bulk_change")
      assert_match %r{\Ahttp://www\.example\.com/backoffice/selections/[0-9a-f-]{36}/bulk_change\?change=}, result["review_url"]
      get result["review_url"]
      assert_response :success
      assert_equal 4, @bob.reload.points
    end
  end

  def test_operator_can_revise_subset_and_values_before_confirming_and_old_preview_is_invalidated
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      original_url = review_link(chat)
      get original_url
      assert_response :success
      assert_select "table.raa-bulk-review tbody tr", count: 2
      assert_select "form#raa-bulk-review input[type=checkbox][name='target_ids[]']", count: 2

      confirm_form = css_select("form[action$='/bulk_change']").first
      old_fields = browser_fields(confirm_form)
      review_form = css_select("form#raa-bulk-review").first
      revise_action = review_form.at_css("button[formaction]")["formaction"]
      change_token = review_form.css("input[name='change']").first["value"]

      # Untick Cara and adjust points to 7: creates a fresh preview, writes nothing.
      post revise_action, params: { change: change_token, target_ids: [ @bob.id.to_s ], values: { points: "7" } }
      assert_response :see_other
      assert_equal [ 4, 9 ], [ @bob.reload.points, @cara.reload.points ], "revising never writes records"
      refute_equal original_url, response.location
      revised_url = response.location

      # Old preview token and confirm form are permanently invalidated.
      get original_url
      assert_response :conflict
      post confirm_form["action"], params: old_fields.merge("decision" => "confirm")
      assert_response :conflict

      # Revised review shows only Bob with 4 -> 7; confirming updates only Bob.
      get revised_url
      assert_response :success
      assert_select "table.raa-bulk-review tbody tr", count: 1
      assert_select "table.raa-bulk-review td", text: /4 → 7/
      decide("confirm")
      assert_response :success
      assert_equal [ 7, 9 ], [ @bob.reload.points, @cara.reload.points ]
      assert_equal 1, chat.turns.where(kind: "continuation").count
      assert_includes chat.turns.find_by!(kind: "continuation").content, "1 of 1 records were updated"
    end
  end

  # The row checkboxes and the value fields belong to the form that confirms,
  # so a review the operator changed on screen never applies the old plan.
  def test_confirming_after_unticking_rows_or_editing_values_writes_nothing
    with_bulk do
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s, @cara.id.to_s ] })
      get review_link(chat)
      assert_response :success
      confirm_form = css_select("form[action$='/bulk_change']").first
      assert confirm_form.at_css("button[name='decision'][value='confirm']")
      assert_select "form#raa-bulk-review input[type=hidden][name='target_ids[]'][value='']", count: 1
      boxes = css_select("input[type=checkbox][name='target_ids[]']")
      assert_equal 2, boxes.size
      boxes.each do |box|
        assert box["form"].nil? ? box.ancestors("form").include?(confirm_form) : box["form"] == confirm_form["id"],
          "each row checkbox is submitted with the confirmation"
      end
      fields = browser_fields(confirm_form).except("target_ids", "values")

      post confirm_form["action"], params: fields.merge("decision" => "confirm", "target_ids" => [ "", @bob.id.to_s ])
      assert_response :unprocessable_content
      post confirm_form["action"], params: fields.merge("decision" => "confirm", "target_ids" => [ "" ])
      assert_response :unprocessable_content
      post confirm_form["action"], params: fields.merge("decision" => "confirm",
        "target_ids" => [ "", @bob.id.to_s, @cara.id.to_s ], "values" => { "points" => "7" })
      assert_response :unprocessable_content
      assert_equal [ 4, 9 ], [ @bob.reload.points, @cara.reload.points ]
      assert_empty RailsAiAdmin::OperationRun.all

      # The unchanged review still confirms both records.
      post confirm_form["action"], params: fields.merge("decision" => "confirm",
        "target_ids" => [ "", @bob.id.to_s, @cara.id.to_s ], "values" => { "points" => "1" })
      assert_response :success
      assert_equal [ 1, 1 ], [ @bob.reload.points, @cara.reload.points ]
    end
  end

  def test_revise_rejects_empty_selection_unselected_ids_unproposed_fields_and_invalid_values
    with_bulk do
      other = Customer.create!(account_id: 2, name: "Foreign", points: 50)
      chat = start_chat
      propose(chat, { resource: "changeable_customers", values: { points: 1 }, ids: [ @bob.id.to_s ] })
      original_url = review_link(chat)
      get original_url
      review_form = css_select("form#raa-bulk-review").first
      revise_action = review_form.at_css("button[formaction]")["formaction"]
      token = review_form.css("input[name='change']").first["value"]

      # Empty subset rejected without closing the original preview.
      post revise_action, params: { change: token, target_ids: [], values: { points: "2" } }
      assert_response :unprocessable_content

      # Unselected / foreign ID rejected.
      post revise_action, params: { change: token, target_ids: [ @bob.id.to_s, other.id.to_s ], values: { points: "2" } }
      assert_response :unprocessable_content

      # Unproposed field smuggling rejected.
      post revise_action, params: { change: token, target_ids: [ @bob.id.to_s ], values: { points: "2", name: "Hacked" } }
      assert_response :unprocessable_content

      # Invalid typed value rejected.
      post revise_action, params: { change: token, target_ids: [ @bob.id.to_s ], values: { points: "not-a-number" } }
      assert_response :unprocessable_content

      # Original preview remains open and unmodified.
      get original_url
      assert_response :success
      assert_equal [ 4, 50 ], [ @bob.reload.points, other.reload.points ]
    end
  end
end
