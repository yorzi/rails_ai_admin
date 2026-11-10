# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

# End-to-end regressions for the input-integrity findings (RAA-002, RAA-004,
# RAA-005 part 1, RAA-014, RAA-016) through the conventional pages.
class InputIntegrityPagesTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class PaymentResource < RailsAiAdmin::Resource
    model "Payment"
    key :payments
    title :id
    fields do
      id :id
      text :reference
      textarea :note
      decimal :amount
      datetime :paid_at
    end
  end

  class Policy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      return super unless resource == PaymentResource
      return %i[id reference note amount paid_at] if action == :read
      return %i[reference note amount paid_at] if action == :write
      []
    end
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_payments
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "InputIntegrityPagesTest::Policy"
    registry = RailsAiAdmin::Registry.new([ "InputIntegrityPagesTest::PaymentResource" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  # Every value the browser would submit for the rendered form, unchanged.
  def submitted_form_values
    values = {}
    css_select("input[name^='record[']").each { |input| values[input["name"][/\Arecord\[(.+)\]\z/, 1]] = input["value"].to_s }
    css_select("textarea[name^='record[']").each { |area| values[area["name"][/\Arecord\[(.+)\]\z/, 1]] = area.text.delete_prefix("\n") }
    values
  end

  def test_raa_002_saving_an_unchanged_form_keeps_null_text_columns_null
    payment = Payment.create!(account_id: 1, amount: "10.5")
    with_payments do
      get "/backoffice/payments/#{payment.id}/edit"
      assert_response :success
      values = submitted_form_values
      assert_equal({ "reference" => "", "note" => "", "amount" => "10.50", "paid_at" => "" }, values)
      patch "/backoffice/payments/#{payment.id}", params: { intent_ref: intent, record: values }
      assert_response :see_other
    end
    payment.reload
    assert_nil payment.reference
    assert_nil payment.note
    assert_equal BigDecimal("10.5"), payment.amount
    assert_equal 0, payment.lock_version
    event = RailsAiAdmin::AuditEvent.find_by!(status: "succeeded")
    assert_empty event.changed_fields
  end

  def test_raa_004_and_014_decimal_errors_name_the_field_and_display_keeps_the_scale
    payment = Payment.create!(account_id: 1, amount: "534.8")
    with_payments do
      get "/backoffice/payments/#{payment.id}"
      assert_response :success
      assert_includes response.body, "534.80"
      get "/backoffice/payments/#{payment.id}/edit"
      patch "/backoffice/payments/#{payment.id}", params: { intent_ref: intent, record: { amount: "1234.567" } }
      assert_response :unprocessable_content
      assert_includes response.body, "must have at most 2 decimal places"
      patch "/backoffice/payments/#{payment.id}", params: { intent_ref: intent, record: { amount: "99999999.99" } }
      assert_response :unprocessable_content
      assert_includes response.body, "is out of range"
    end
    assert_equal BigDecimal("534.8"), payment.reload.amount
  end

  def test_raa_016_a_nul_byte_is_a_field_error_not_a_server_error
    with_payments do
      get "/backoffice/payments/new"
      post "/backoffice/payments", params: { intent_ref: intent, record: { reference: "a\u0000b", note: "ok" } }
      assert_response :unprocessable_content
      assert_includes response.body, "contains control characters"
    end
    assert_equal 0, Payment.count
  end

  def test_raa_005_layout_disables_turbo_hover_prefetch
    get "/backoffice/customers"
    assert_response :success
    assert_select "meta[name='turbo-prefetch'][content='false']"
  end
end
