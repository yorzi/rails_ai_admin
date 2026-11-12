# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class FormPresentationTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class CollisionLabel < RailsAiAdmin::Fields::Computation
    def call(values, **) = "Context for #{values.fetch('name')}"
  end
  class Resource < RailsAiAdmin::Resource
    model "Customer"
    key :form_customers
    title :name
    fields do
      id :id, create: false, edit: false
      text :name, required: true, nullable: false, index: false, tab: "Identity", panel: "Basics", help_text: "<b>Preferred name</b>"
      integer :points, tab: "Account", panel: "Rewards", help_text: "Use whole points."
      boolean :active, readonly: true, create: false, edit: true, tab: "Account", panel: "Context"
      virtual :name_help, type: :text, depends_on: [ :name ], compute: "FormPresentationTest::CollisionLabel", index: false, edit: true, tab: "Identity"
      virtual :name_error, type: :text, depends_on: [ :name ], compute: "FormPresentationTest::CollisionLabel", index: false, edit: true, tab: "Identity"
      text :secret, hidden: true, tab: "Private tab", panel: "Private panel"
    end
  end
  class Policy < TestPolicy
    class_attribute :mask, default: nil
    def presentation_fields(**) = mask
    def fields(**) = super + %i[secret name_help name_error]
  end

  def setup
    reset_database
    Policy.mask = nil
    post "/test/sign_in/1"
  end

  def with_form_resource
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "FormPresentationTest::Policy"
    registry = RailsAiAdmin::Registry.new([ "FormPresentationTest::Resource" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def edit_path = "/backoffice/form_customers/#{@customer.id}/edit"
  def member_path = "/backoffice/form_customers/#{@customer.id}"
  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_progressive_layout_readonly_context_and_plain_help
    with_form_resource do
      get edit_path
      assert_response :success
      assert_select ".raa-tab-links a", text: "Identity"
      assert_select ".raa-tab-links a", text: "Account"
      assert_select "section[hidden]", count: 0
      assert_select "fieldset legend", text: "Basics"
      assert_select ".raa-readonly[role=group]", text: "Yes"
      assert_select "input[name='record[active]']", count: 0
      input = css_select("input[name='record[name]'][aria-describedby]").first
      assert input
      assert_select "##{input['aria-describedby']}", text: "<b>Preferred name</b>"
      refute_includes response.body, "<b>Preferred name</b>"
      refute_includes response.body, "Private tab"
      refute_includes response.body, "Private panel"
      refute_includes response.body, "never show"
      ids = css_select("[id]").map { |node| node["id"] }
      assert_equal ids.uniq, ids
    end
  end

  def test_validation_retains_raw_input_and_connects_summary_help_and_field_error
    with_form_resource do
      get edit_path
      token = intent
      patch member_path, params: { intent_ref: token, record: { name: "", points: "08" } }
      assert_response :unprocessable_content
      assert_select "input[name='record[points]'][value='08']"
      input = css_select("input[name='record[name]'][aria-invalid=true]").first
      assert input
      assert_equal 2, input["aria-describedby"].split.size
      input["aria-describedby"].split.each { |id| assert_select "##{id}" }
      assert_select ".raa-errors a[data-raa-target-field='#{input['id']}'][href='##{input['id']}']"
      assert_select ".raa-errors[tabindex='-1'][data-controller=raa-error-summary]"
      ids = css_select("[id]").map { |node| node["id"] }
      assert_equal ids.uniq, ids
      assert_equal token, intent
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_view_mask_removes_empty_groups_and_rejects_forged_hidden_inputs
    with_form_resource do
      Policy.mask = [ :name ]
      get edit_path
      assert_response :success
      assert_select "input[name='record[name]']"
      assert_select "input[name='record[points]']", count: 0
      refute_includes response.body, "Account"
      token = intent
      patch member_path, params: { intent_ref: token, record: { points: "7" } }
      assert_response :unprocessable_content
      refute_includes response.body, 'value="7"'
      assert_equal 0, @customer.reload.points
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  end

  def test_write_only_fields_never_prefill_private_database_values
    with_form_resource do
      TestPolicy.hide_name = true
      get edit_path
      assert_response :success
      assert_select "input[name='record[name]']" do |nodes|
        assert_includes [ nil, "" ], nodes.first["value"]
      end
      refute_includes response.body, "Alice"
      TestPolicy.deny_show = true
      get "/backoffice/form_customers/new"
      assert_response :success
      assert_select ".raa-readonly", count: 0
      assert_select "input[name='record[name]']"
    end
  end

  def test_index_presentation_does_not_leak_hidden_title_through_link_labels
    with_form_resource do
      get "/backoffice/form_customers"
      assert_response :success
      refute_includes response.body, "Alice"
      assert_includes response.body, "Record ##{@customer.id}"
      get member_path
      assert_response :success
      assert_includes response.body, "Alice"
    end
  end
end
