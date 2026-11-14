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
      assert_select "input[type=hidden][name='back[resource]'][value=customers]"
      assert_select "a[href='/backoffice/customers/#{@customer.id}']", text: "Cancel"
      post "/backoffice/invoices", params: { intent_ref: intent, record: { number: "INV-NEW", customer: @customer.id.to_s },
        back: { resource: "customers", id: @customer.id.to_s } }
      assert_response :see_other
      assert_equal "/backoffice/customers/#{@customer.id}", URI(response.location).path, "saving returns to the parent"
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

  def test_children_are_edited_and_deleted_from_the_parent_page
    invoice = Invoice.create!(account_id: 1, number: "INV-1", customer: @customer)
    with_association_resources do
      get "/backoffice/customers/#{@customer.id}"
      edit = css_select("section.raa-association a.raa-row-edit").first
      assert_equal "Edit", edit.text
      get edit["href"]
      assert_response :success
      assert_select "a[href='/backoffice/customers/#{@customer.id}']", text: "Cancel"
      intent = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/invoices/#{invoice.id}", params: { intent_ref: intent, record: { number: "INV-1B", customer: @customer.id.to_s },
        back: { resource: "customers", id: @customer.id.to_s } }
      assert_response :see_other
      assert_equal "/backoffice/customers/#{@customer.id}", URI(response.location).path
      assert_equal "INV-1B", invoice.reload.number
      # A back hint to something the actor cannot see falls back to the usual page.
      get "/backoffice/invoices/#{invoice.id}/edit"
      intent = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/invoices/#{invoice.id}", params: { intent_ref: intent, record: { number: "INV-1C", customer: @customer.id.to_s },
        back: { resource: "customers", id: @other.id.to_s } }
      assert_equal "/backoffice/invoices/#{invoice.id}", URI(response.location).path
      [ { resource: "nope", id: "1" }, { resource: "customers", id: "01" }, { resource: "customers" } ].each do |back|
        get "/backoffice/invoices/#{invoice.id}/edit", params: { back: back }
        assert_response :success
        assert_select "input[name='back[resource]']", count: 0, message: back.inspect
      end
    end
    post "/test/sign_in/2"
    with_association_resources do
      get "/backoffice/customers/#{@customer.id}"
      assert_select "section.raa-association a.raa-row-edit", count: 0, message: "readers get no Edit link"
    end
  end
end
