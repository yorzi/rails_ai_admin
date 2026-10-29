require "test_helper"

class RailsAiAdminAccessTest < ActionDispatch::IntegrationTest
  test "anonymous access stays closed" do
    get Rails.application.routes.url_helpers.rails_ai_admin_path
    assert_response :unauthorized
  end
end
