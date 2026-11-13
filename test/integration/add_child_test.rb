# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/associations"
require "minitest/mock"

# "Add" on a child panel opens the child's new form pointing at the parent.
class AddChildIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AssociationFixtures

  def setup
    reset_database
    AssociationFixtures::Policy.reset!
    post "/test/sign_in/1"
  end

  def test_the_panel_links_a_prefilled_new_child_form
    with_association_resources do
      get "/backoffice/customers/#{@customer.id}"
      link = css_select("section.raa-association a").find { |node| node.text == "Add invoice" }
      assert link
      get link["href"]
      assert_response :success
      assert_select "select[name='record[customer]'] option[selected][value='#{@customer.id}']"
      intent = css_select("input[name=intent_ref]").first["value"]
      post "/backoffice/invoices", params: { intent_ref: intent, record: { number: "INV-NEW", customer: @customer.id.to_s } }
      assert_response :see_other
      assert_equal @customer.id, Invoice.find_by!(number: "INV-NEW").customer_id
    end
  end

  def test_unavailable_or_invalid_prefills_are_ignored_and_readers_get_no_link
    with_association_resources do
      get "/backoffice/invoices/new", params: { prefill: { customer: @other.id.to_s } }
      assert_response :success
      assert_select "select[name='record[customer]'] option[selected][value='#{@other.id}']", count: 0
      get "/backoffice/invoices/new", params: { prefill: { customer: "x y", number: "forced" } }
      assert_response :success
      assert_select "input[name='record[number]'][value=forced]", count: 0
    end
    post "/test/sign_in/2"
    with_association_resources do
      get "/backoffice/customers/#{@customer.id}"
      assert_empty css_select("section.raa-association a").select { |node| node.text.start_with?("Add") }
    end
  end
end
