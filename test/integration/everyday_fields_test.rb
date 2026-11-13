# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# Pages for time, email, url, json and password fields on a model with no
# lock_version.
class EverydayFieldsIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @article.update!(contact: "ada@example.com", website: "https://example.com/docs", opens_at: "08:30",
      settings: { "theme" => "<b>dark</b>" }, password: "stored password")
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_show_and_index_link_safely_and_never_reveal_a_password
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}"
      assert_response :success
      assert_select "a[href='mailto:ada@example.com']", text: "ada@example.com"
      assert_select "a[href='https://example.com/docs'][rel='noopener noreferrer nofollow'][target=_blank]"
      assert_select "pre.raa-json", text: /"theme": "<b>dark<\/b>"/
      refute_includes response.body, "<b>dark</b>"
      assert_select "dd", text: "08:30"
      refute_includes response.body, @article.password_digest
      refute_includes response.body, "Password"

      get "/backoffice/articles"
      assert_response :success
      assert_select "td a[href='mailto:ada@example.com']"
      assert_select "td", text: /"theme": "<b>dark<\/b>"/
      refute_includes response.body, @article.password_digest

      # A stored address that is not http(s) stays text.
      @article.update_column(:website, "javascript:alert(1)")
      get "/backoffice/articles/#{@article.id}"
      assert_select "a[href^='javascript']", count: 0
      assert_select "dd", text: "javascript:alert(1)"
    end
  end

  def test_edit_uses_typed_inputs_and_an_empty_password_keeps_the_current_one
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/edit"
      assert_response :success
      assert_select "input[type=email][name='record[contact]'][value='ada@example.com']"
      assert_select "input[type=url][name='record[website]']"
      assert_select "input[type=time][name='record[opens_at]'][value='08:30']"
      assert_select "textarea.raa-json-input[name='record[settings]']", text: /"theme"/
      assert_select "input[type=password][name='record[password]'][autocomplete=new-password]:not([value]):not([required])"
      assert_select "#raa_articles_record_password--keep, p.raa-field-help", text: /Leave blank to keep the current password/
      digest = @article.password_digest
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { title: "First", views: "1",
        contact: "ada@example.com", website: "https://example.com/docs", opens_at: "09:15", settings: '{"theme":"light"}', password: "" } }
      assert_response :see_other
      @article.reload
      assert_equal digest, @article.password_digest
      assert_equal "09:15", @article.opens_at.strftime("%H:%M")
      assert_equal({ "theme" => "light" }, @article.settings)
    end
  end

  def test_a_failed_save_shows_messages_and_never_echoes_the_password
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/edit"
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { title: "First",
        contact: "not an address", website: "javascript:alert(1)", opens_at: "25:00", settings: "{", password: "typed secret" } }
      assert_response :unprocessable_content
      assert_select "p.raa-field-error", text: "must be an email address"
      assert_select "p.raa-field-error", text: "must be an http or https address"
      assert_select "p.raa-field-error", text: "must be a time of day (HH:MM)"
      assert_select "p.raa-field-error", text: "must be valid JSON"
      refute_includes response.body, "typed secret"
      assert_select "input[type=password]:not([value])"

      # The model's own validation still applies to a new password.
      get "/backoffice/articles/#{@article.id}/edit"
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { password: "short" } }
      assert_response :unprocessable_content
      refute_includes response.body, "short\""
      assert @article.reload.authenticate("stored password")

      get "/backoffice/articles/#{@article.id}/edit"
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { password: "a brand new password" } }
      assert_response :see_other
      assert @article.reload.authenticate("a brand new password")
      assert_equal [ "password" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields
    end
  end

  def test_create_and_a_concurrent_edit_without_lock_version
    with_essential_resources do
      get "/backoffice/articles/new"
      assert_response :success
      post "/backoffice/articles", params: { intent_ref: intent, record: { title: "Created", opens_at: "07:00", password: "initial password" } }
      assert_response :see_other
      created = Article.find_by!(title: "Created")
      assert created.authenticate("initial password")

      get "/backoffice/articles/#{@article.id}/edit"
      ref = intent
      @article.update!(title: "Changed elsewhere")
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: ref, record: { title: "Mine" } }
      assert_response :conflict
      assert_equal "Changed elsewhere", @article.reload.title
    end
  end
end
