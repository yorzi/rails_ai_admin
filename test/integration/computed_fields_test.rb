# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class NativeComputedFieldsTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class Summary < RailsAiAdmin::Fields::Computation
    class_attribute :calls, default: 0
    def call(values, **)
      self.class.calls += 1
      "#{values.fetch('name')} (#{values.fetch('points')})"
    end
  end
  class Resource < RailsAiAdmin::Resource
    model "Customer"
    key :computed_customers
    title :summary
    fields do
      id :id
      text :name
      integer :points
      virtual :summary, type: :text, depends_on: %i[name points], compute: "NativeComputedFieldsTest::Summary"
    end
  end
  class Policy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      grants = super + [ :summary ]
      action == :read && record&.name == "Private name" ? grants - [ :name ] : grants
    end
    def select_records?(**) = true
  end

  def setup
    reset_database
    Summary.calls = 0
    post "/test/sign_in/1"
  end

  def with_resource
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "NativeComputedFieldsTest::Policy"
    registry = RailsAiAdmin::Registry.new([ "NativeComputedFieldsTest::Resource" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def test_index_show_and_selection_use_the_same_computed_title
    with_resource do
      get "/backoffice/computed_customers"
      assert_response :success
      assert_select "td", text: "Alice (0)"
      assert_select "a", text: "View Alice (0)"
      assert_equal 1, Summary.calls
      get "/backoffice/computed_customers/#{@customer.id}"
      assert_select "dd", text: "Alice (0)"
      post "/backoffice/computed_customers/selections", params: { target_ids: [ @customer.id ] }
      assert_response :see_other
      get URI(response.location).path
      assert_response :success
      assert_includes response.body, "Alice (0)"
    end
  end

  def test_row_dependency_denial_skips_computation_and_title_falls_back
    @customer.update!(name: "Private name")
    with_resource do
      get "/backoffice/computed_customers"
      assert_response :success
      assert_select "a", text: "View Record ##{@customer.id}"
      refute_includes response.body, "Private name"
      assert_equal 0, Summary.calls
      post "/backoffice/computed_customers/selections", params: { target_ids: [ @customer.id ] }
      get URI(response.location).path
      assert_response :success
      refute_includes response.body, "Private name"
      assert_equal 0, Summary.calls
    end
  end

  def test_forged_write_search_and_sort_cannot_target_computed_field
    with_resource do
      get "/backoffice/computed_customers/#{@customer.id}/edit"
      assert_response :success
      assert_select "input[name='record[summary]']", count: 0
      token = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/computed_customers/#{@customer.id}", params: { intent_ref: token, record: { summary: "Attack" } }
      assert_response :unprocessable_content
      assert_equal "Alice", @customer.reload.name
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
      get "/backoffice/computed_customers", params: { sort: "summary" }
      assert_response :unprocessable_content
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_page_of_computed_titles_does_not_add_record_queries
    24.times { |index| Customer.create!(account_id: 1, name: "Customer #{index}", points: index) }
    queries = []
    listener = ->(*args) do
      payload = args.last
      queries << payload[:sql] if payload[:sql].match?(/\bFROM\s+"?customers"?\b/i) && !payload[:cached]
    end
    with_resource do
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { get "/backoffice/computed_customers" }
      assert_response :success
      assert_equal 25, Summary.calls
      assert_equal 1, queries.size, queries.join("\n")
    end
  end

  def test_computed_text_is_escaped_and_failure_details_are_hidden
    @customer.update!(name: "<script>private()</script>")
    with_resource do
      get "/backoffice/computed_customers/#{@customer.id}"
      assert_response :success
      refute_includes response.body, "<script>private()</script>"
      assert_includes response.body, "&lt;script&gt;"
      handler = Summary.new
      handler.define_singleton_method(:call) { |*, **| raise "private failure diagnostic" }
      Summary.stub(:new, handler) do
        get "/backoffice/computed_customers/#{@customer.id}"
        assert_response :service_unavailable
        refute_includes response.body, "private failure"
        refute_includes response.body, "private()"
      end
    end
  end
end
