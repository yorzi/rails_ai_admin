require "test_helper"

class RailsAiAdminAccessTest < ActionDispatch::IntegrationTest
  # Closed means no admin page renders: a 401, or with config.authentication_path
  # a redirect to sign-in.
  test "anonymous access stays closed" do
    path = Rails.application.routes.url_helpers.rails_ai_admin_path
    get path
    sign_in = RailsAiAdmin.configuration.authentication_path
    if sign_in
      assert_response :see_other
      assert_equal sign_in, URI(response.location).path
    else
      assert_response :unauthorized
    end
  end
end
