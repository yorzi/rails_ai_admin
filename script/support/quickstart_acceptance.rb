# frozen_string_literal: true

require_relative "../config/environment"
require "minitest/autorun"
require "action_dispatch/testing/integration"

class QuickstartAcceptanceTest < ActionDispatch::IntegrationTest
  def token = css_select("input[name=authenticity_token]").first["value"]

  def test_generated_admin_authentication_crud_and_revocation
    ActionController::Base.allow_forgery_protection = true
    User.delete_all
    user = User.create!(email_address: "admin@example.test", password: "synthetic-test-password", admin: true)
    assert_equal %w[articles users], RailsAiAdmin.registry.resources.map { |resource| resource.key.to_s }.sort
    refute UserAdmin.fields.any? { |field| %i[admin password_digest].include?(field.name) }
    # A user needs a password the generated resource leaves out, so creating
    # one is off until the host enables the password field.
    refute UserAdmin.action_enabled?(:create)
    assert UserAdmin.action_enabled?(:update)
    get "/admin/articles"
    assert_equal "/session/new", URI.parse(response.location).path
    get "/session/new"
    post "/session", params: { authenticity_token: token, email_address: user.email_address, password: "synthetic-test-password" }
    assert_response :redirect
    get "/admin/users"
    assert_response :success
    assert_select "a", text: "New user", count: 0
    get "/admin/users/new"
    assert_response :not_found
    get "/admin/articles/new"
    assert_response :success
    assert_select ".raa-actor", text: user.email_address
    form = css_select("form[action='/admin/articles']").first
    post "/admin/articles", params: { authenticity_token: form.at_css("input[name=authenticity_token]")["value"],
      intent_ref: form.at_css("input[name=intent_ref]")["value"], record: { title: "Generated article", body: "Hello" } }
    assert_response :redirect
    article = Article.find_by!(title: "Generated article")
    get "/admin/articles/#{article.id}/edit"
    assert_response :success
    form = css_select("form[action='/admin/articles/#{article.id}']").first
    patch "/admin/articles/#{article.id}", params: { authenticity_token: form.at_css("input[name=authenticity_token]")["value"],
      intent_ref: form.at_css("input[name=intent_ref]")["value"], record: { title: "Reviewed article" } }
    assert_response :redirect
    assert_equal "Reviewed article", article.reload.title
    assert_operator RailsAiAdmin::AuditEvent.count, :>=, 2
    user.update!(admin: false)
    get "/admin/articles"
    assert_equal "/session/new", URI.parse(response.location).path
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
