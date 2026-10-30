# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class ResourceNavigationTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def test_grouped_escaped_labels_icons_and_active_resource_use_the_actual_mount_and_relative_root
    options = RailsAiAdmin::Navigation::Settings.new(group: "商务 <group>", label: "Clients <script>", icon: "users", order: -1)
    TestResource.stub(:navigation, options) do
      get "/backoffice/customers/#{@customer.id}", env: { "SCRIPT_NAME" => "/portal" }
      assert_response :success
      assert_select "nav[aria-label='Admin resources']" do
        assert_select "[role=group][aria-labelledby=raa-nav-group-0]"
        assert_select "h2#raa-nav-group-0", text: "商务 <group>"
        assert_select "a[aria-current=location][href='/portal/backoffice/customers']", text: "Clients <script>"
        assert_select "a[aria-current=location] svg[aria-hidden=true][focusable=false] path"
        assert_select "script", count: 0
      end
      refute_includes response.body, "Clients <script>"
      assert_includes response.body, "Clients &lt;script&gt;"
      get "/backoffice", params: { resource: "customers" }
      assert_response :success
      assert_select "nav a[aria-current=page]", text: "Overview"
      assert_select "nav a[aria-current=location]", count: 0
      assert_select ".raa-cards a[href='/backoffice/customers']", text: "Clients <script>"
    end
  end

  def test_every_accepted_icon_name_has_a_fixed_glyph
    assert_equal RailsAiAdmin::Navigation::Settings::ICONS, RailsAiAdmin::NavigationHelper::ICON_PATHS.keys
  end

  def test_hidden_navigation_is_absent_from_sidebar_and_overview_but_direct_urls_keep_current_policy
    hidden = RailsAiAdmin::Navigation::Settings.new(group: "Hidden navigation group", hidden: true)
    TestResource.stub(:navigation, hidden) do
      get "/backoffice"
      assert_response :success
      assert_select "nav a[href='/backoffice/customers']", count: 0
      assert_select ".raa-cards a[href='/backoffice/customers']", count: 0
      refute_includes response.body, "Hidden navigation group"
      get "/backoffice/customers"
      assert_response :success
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_response :success
      assert_select "input[name=intent_ref]"
      TestPolicy.denied = true
      get "/backoffice/customers/#{@customer.id}"
      assert_response :not_found
      refute_includes response.body, "Alice"
    end
  end

  def test_denied_resources_leave_no_group_or_overview_item_and_the_next_request_uses_new_grants
    settings = RailsAiAdmin::Navigation::Settings.new(group: "Restricted group", label: "Restricted customer menu")
    TestResource.stub(:navigation, settings) do
      get "/backoffice"
      assert_includes response.body, "Restricted customer menu"
      TestPolicy.denied = true
      get "/backoffice"
      assert_response :success
      assert_select ".raa-cards li", count: 0
      assert_includes response.body, "No resources are available"
      refute_includes response.body, "Restricted group"
      refute_includes response.body, "Restricted customer menu"
    end
  end
end
