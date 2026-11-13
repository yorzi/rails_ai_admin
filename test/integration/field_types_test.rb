# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class NativeFieldTypesTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class EmailType < RailsAiAdmin::Fields::Type
    scalar :text
    form_partial "field_types/input"
    index_partial "field_types/display"
    show_partial "field_types/display"
    def normalize(value, **) = value.strip.downcase
    def valid?(value, **) = value.include?("@")
    def format(text, **) = "<#{text}>".html_safe
  end

  class RowPolicy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      grants = super
      action == :read && record&.name == "Alice" ? grants - [ :name ] : grants
    end
  end

  class TimestampPolicy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      super + (%i[read write].include?(action) ? [ :created_at ] : [])
    end
  end

  class NumberType < RailsAiAdmin::Fields::Type
    scalar :integer
    index_partial "field_types/display"
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_fields(*fields)
    TestResource.stub(:fields, fields) { yield }
  end

  def email
    RailsAiAdmin::Fields::Registry.new(contact_email: "NativeFieldTypesTest::EmailType").build(:name, type: :contact_email, nullable: false)
  end

  def test_custom_form_display_and_normalized_write_use_shared_operation
    with_fields(email) do
      get "/backoffice/customers/#{@customer.id}"
      assert_response :success
      assert_select "[data-custom-field=email]", text: "<Alice>"
      refute_includes response.body, "<Alice>"
      get "/backoffice/customers"
      assert_select "td [data-custom-field=email]", text: "<Alice>"
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_select "input[data-custom-field=email][value=Alice]"
      token = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "invalid" } }
      assert_response :unprocessable_content
      assert_select "input[data-custom-field=email][value=invalid][aria-invalid=true]"
      assert_select ".raa-field-error", text: "is invalid"
      assert_equal "Alice", @customer.reload.name
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: " Alice@Example.COM " } }
      assert_response :see_other
      assert_equal "alice@example.com", @customer.reload.name
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end

  def test_rebuilt_plugin_version_invalidates_a_previously_rendered_form
    original = EmailType.version
    with_fields(email) do
      get "/backoffice/customers/#{@customer.id}/edit"
    end
    token = css_select("input[name=intent_ref]").first["value"]
    EmailType.version "2"
    with_fields(email) do
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "alice@example.com" } }
      assert_response :conflict
      assert_equal "Alice", @customer.reload.name
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    end
  ensure
    EmailType.version original
  end

  def test_field_policy_prevents_custom_partial_and_posted_write
    with_fields(email) do
      TestPolicy.hide_name = true
      get "/backoffice/customers/#{@customer.id}"
      assert_response :success
      assert_select "[data-custom-field=email]", count: 0
      post "/test/sign_in/2"
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_response :not_found
    end
  end

  def test_record_field_denial_does_not_invoke_a_display_partial
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "NativeFieldTypesTest::RowPolicy"
    Customer.create!(account_id: 1, name: "Visible row")
    RailsAiAdmin.stub(:configuration, config) do
      with_fields(email) do
        get "/backoffice/customers"
        assert_response :success
        assert_select "td [data-custom-field=email]", count: 1
        assert_select "td [data-custom-field=email]", text: "<Visible row>"
        refute_includes response.body, "&lt;Alice&gt;"
      end
    end
  end

  def test_authorized_null_still_renders_its_display_partial
    @customer.update!(points: nil)
    field = RailsAiAdmin::Fields::Registry.new(number: "NativeFieldTypesTest::NumberType").build(:points, type: :number)
    with_fields(field) do
      get "/backoffice/customers"
      assert_response :success
      assert_select "td [data-custom-field=email]", text: "—"
    end
  end

  # RAA-015: a native datetime-local input in the context zone, a readable
  # display with the exact value in <time>, and an unchanged save that keeps
  # the stored microseconds.
  def test_datetime_form_and_display_preserve_microseconds
    @customer.update!(created_at: Time.iso8601("2026-10-30T01:30:00.123456Z"))
    field = RailsAiAdmin::Field.new(:created_at, type: :datetime)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "NativeFieldTypesTest::TimestampPolicy"
    RailsAiAdmin.stub(:configuration, config) do
      with_fields(field) do
        get "/backoffice/customers/#{@customer.id}/edit"
        assert_response :success
        assert_select "input[type='datetime-local'][name='record[created_at]'][value='2026-10-30T01:30'][step='1']"
        token = css_select("input[name=intent_ref]").first["value"]
        get "/backoffice/customers/#{@customer.id}"
        assert_select "dd time[datetime='2026-10-30T01:30:00Z']", text: "30 Oct 2026 01:30 UTC"
        patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { created_at: "2026-10-30T01:30" } }
        assert_response :see_other
        version = @customer.lock_version
        assert_equal 123_456, @customer.reload.created_at.usec
        assert_equal version, @customer.lock_version, "an unchanged save writes nothing"
      end
    end
  end

  def test_select_preserves_unavailable_value_and_uses_labels
    field = RailsAiAdmin::Field.new(:name, type: :select, choices: [ [ "Pending review", "pending" ], [ "Approved", "approved" ] ], nullable: false)
    with_fields(field) do
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_select "option[selected][disabled][value=Alice]"
      assert_select "option[value=pending]", text: "Pending review"
      token = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "pending" } }
      assert_response :see_other
      get "/backoffice/customers/#{@customer.id}"
      assert_select "dd", text: "Pending review"
    end
  end

  # A select with no blank option cannot carry HTML `required` (Rails raises);
  # aria-required still marks the field (RAA-023).
  def test_required_boolean_without_blank_option_renders
    fields = [ RailsAiAdmin::Field.new(:active, type: :boolean, nullable: false), RailsAiAdmin::Field.new(:points, type: :integer, required: true) ]
    with_fields(*fields) do
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_response :success
      assert_select "select[name='record[active]'][aria-required=true]"
      assert_select "select[name='record[active]'][required]", count: 0
      assert_select "select[name='record[active]'] option[value='']", count: 0
      assert_select "input[name='record[points]'][required]"
    end
  end

  def test_readonly_field_is_hidden_from_form_and_cannot_be_written
    field = RailsAiAdmin::Field.new(:name, type: :text, readonly: true)
    with_fields(field, RailsAiAdmin::Field.new(:points, type: :integer)) do
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_select "input[name='record[name]']", count: 0
      token = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Attack" } }
      assert_response :unprocessable_content
      assert_equal "Alice", @customer.reload.name
    end
  end
end
