# frozen_string_literal: true

require "test_helper"
require "support/assistant"

# Phase 3 regressions from the 2026-11-10 audit: the assistant must not report
# a scoped, display-formatted or failed result as the whole truth.
class AssistantTrustTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include AssistantHelpers
  include ActiveJob::TestHelper

  Coordinator = RailsAiAdmin::Assistant::Coordinator

  class ScopedContractCustomerAdmin < RailsAiAdmin::Resource
    model "Customer"
    key :contract_customers
    title :name
    fields do
      id :id
      text :name, searchable: :contains, sortable: true
      integer :points
    end
    scopes do
      scope :rewarded, -> { where(points: 1..) }, label: "Rewarded", default: true
    end
  end

  def setup
    reset_database
    reset_assistant
    @customer.update!(name: "Alice", points: 0)
    @bob = Customer.create!(account_id: 1, name: "Bob", points: 5)
    TestPolicy.granted_scopes = [ :rewarded ]
  end

  def with_scoped_customers
    with_assistant(resources: [ "AssistantTrustTest::ScopedContractCustomerAdmin" ]) do
      yield RailsAiAdmin::Assistant::Session.new(context: context, chat: new_chat, fence: -> { })
    end
  end

  def test_raa_007_search_and_count_cover_every_record_unless_a_scope_is_named
    with_scoped_customers do |session|
      search = RailsAiAdmin::Assistant::SearchRecords.new(session)
      count = RailsAiAdmin::Assistant::CountRecords.new(session)
      all = search.execute(resource: "contract_customers")
      assert_equal %w[Alice Bob], all["records"].map { |record| record["label"] }
      assert_nil all["applied_scope"]
      assert_nil all["applied_sort"]
      scoped = search.execute(resource: "contract_customers", scope: "rewarded", sort: "name", direction: "desc")
      assert_equal %w[Bob], scoped["records"].map { |record| record["label"] }
      assert_equal "rewarded", scoped["applied_scope"]
      assert_equal({ "field" => "name", "direction" => "desc" }, scoped["applied_sort"])
      assert_equal "INVALID_QUERY", search.execute(resource: "contract_customers", scope: "undeclared")["error"]
      assert_equal "INVALID_QUERY", search.execute(resource: "contract_customers", sort: "points")["error"], "points is not a granted sort"
      assert_equal({ "resource" => "contract_customers", "applied_scope" => nil, "count" => 2, "capped" => false },
        count.execute(resource: "contract_customers"))
      assert_equal 1, count.execute(resource: "contract_customers", scope: "rewarded")["count"]
      assert_equal 1, count.execute(resource: "contract_customers", query: "li")["count"]
    end
  end

  def test_raa_007_and_021_describe_lists_scopes_sorts_and_match_modes
    with_scoped_customers do |session|
      described = RailsAiAdmin::Assistant::DescribeResource.new(session).execute(resource: "contract_customers")
      assert_equal [ { "name" => "rewarded", "label" => "Rewarded", "default_in_ui" => true } ], described["scopes"]
      assert_equal [ "name" ], described["sort"]
      assert_equal [ { "field" => "name", "match" => "contains" } ], described["search"]
    end
  end

  def test_raa_001_records_that_deny_show_are_counted_as_omitted
    with_scoped_customers do |session|
      TestPolicy.deny_show = true
      result = RailsAiAdmin::Assistant::SearchRecords.new(session).execute(resource: "contract_customers")
      assert_equal [ [], 2 ], [ result["records"], result["omitted"] ]
    end
  end

  def test_raa_017_values_reach_the_model_as_typed_json
    with_scoped_customers do |session|
      tool = RailsAiAdmin::Assistant::GetRecord.new(session)
      reference = RailsAiAdmin::Fields::Association::Reference.new("7", "Alice", :customers, true)
      hidden = RailsAiAdmin::Fields::Association::Reference.new("8", "Customer #8", nil, false)
      resolver = Object.new
      resolver.define_singleton_method(:reference) { |_field, id| id == "7" ? reference : hidden }
      typed = ->(type, value, **options) { tool.send(:typed, RailsAiAdmin::Field.new(:value, type: type, **options), value, resolver) }
      assert_nil typed.(:text, nil)
      assert_equal true, typed.(:boolean, true)
      assert_equal false, typed.(:boolean, false)
      assert_equal 12, typed.(:integer, 12)
      assert_equal "10.50", typed.(:decimal, BigDecimal("10.5"), scale: 2)
      assert_equal "2026-11-10", typed.(:date, Date.new(2026, 11, 10))
      assert_equal "2026-11-10T02:44:11Z", typed.(:datetime, Time.utc(2026, 11, 10, 2, 44, 11))
      assert_equal({ "value" => "draft", "label" => "Draft" }, typed.(:select, "draft", choices: [ %w[Draft draft] ]))
      assert_equal "—", typed.(:text, "—"), "a literal dash stays text and is distinguishable from null"
      assert_equal({ "id" => "7", "label" => "Alice", "resource" => "customers" }, typed.(:belongs_to, "7", resource: :customers))
      assert_equal({ "id" => "8", "label" => "Customer #8", "resource" => nil }, typed.(:belongs_to, "8", resource: :customers))
    end
  end

  def test_raa_018_activity_lines_report_failed_tool_calls
    with_assistant do
      chat = new_chat
      admit(chat, "Open the other tenant")
      LLMFixture.tool("get_record", { resource: "contract_customers", id: @other.id.to_s })
      LLMFixture.tool("get_record", { resource: "contract_customers", id: @customer.id.to_s })
      LLMFixture.reply("Only Alice is available.")
      drain(chat)
      activity = RailsAiAdmin::Assistant::Transcript.new(context, chat).entries.select { |entry| entry.kind == :activity }.map(&:text)
      assert_equal [ "Tried to open a record in Contract customers (not available)", "Opened a record in Contract customers" ], activity
    end
  end

  def test_raa_008_a_retryable_failure_schedules_its_own_retry
    with_assistant do
      chat = new_chat
      turn = admit(chat, "Hello")
      clear_enqueued_jobs
      LLMFixture.failure(500)
      freeze_time do
        drain(chat)
        assert_enqueued_with(job: RailsAiAdmin::AssistantTurnJob, args: [ chat.ref ], at: 2.seconds.from_now)
      end
      assert_equal "queued", turn.reload.status
    end
  end

  def test_raa_030_an_unanswered_message_is_closed_before_the_next_one
    with_assistant do
      chat = new_chat
      first = admit(chat, "Hello")
      LLMFixture.failure(400)
      drain(chat)
      assert_equal "failed", first.reload.status
      admit(chat, "Are you there?")
      LLMFixture.reply("Yes.")
      drain(chat)
      assert_equal [ [ "user", "Hello" ], [ "assistant", Coordinator::UNANSWERED_NOTE ], [ "user", "Are you there?" ], [ "assistant", "Yes." ] ], transcript(chat)
      sent = LLMFixture.requests.last["messages"].reject { |message| %w[system developer].include?(message["role"]) }.map { |message| message["role"] }
      assert_equal %w[user assistant user], sent
      # After an answered message no note is added.
      admit(chat, "Thanks")
      LLMFixture.reply("You're welcome.")
      drain(chat)
      assert_equal 1, chat.messages.where(content: Coordinator::UNANSWERED_NOTE).count
    end
  end

  def test_daily_message_limit_stops_admission_before_any_provider_call
    with_assistant do
      RailsAiAdmin.configuration.assistant_daily_message_limit = 2
      chat = new_chat
      2.times { |index| admit(chat, "Message #{index}") }
      error = assert_raises(RailsAiAdmin::AccessDenied) { admit(new_chat, "One more") }
      assert_equal "RATE_LIMITED", error.code
      # Another actor has their own allowance; a repeated key is not a new message.
      assert admit(new_chat(actor: 2), "Mine")
      key = "message:#{SecureRandom.uuid}"
      RailsAiAdmin.configuration.assistant_daily_message_limit = 3
      admit(chat, "Third", key: key)
      assert admit(chat, "Third", key: key)
      travel 25.hours do
        assert admit(chat, "Tomorrow")
      end
      RailsAiAdmin.configuration.assistant_daily_message_limit = nil
      assert admit(chat, "Unlimited")
      assert_empty LLMFixture.requests
    end
  end
end
