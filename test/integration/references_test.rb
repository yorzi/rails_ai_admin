# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# Many-to-many editing through a references field, and has_one panels.
class ReferencesIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @ruby, @rails, @secret = %w[Ruby Rails Secret].map { |name| Tag.create!(account_id: 1, name: name) }
    @foreign = Tag.create!(account_id: 2, name: "Foreign")
    @article.tags << @secret
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def edit(tags)
    get "/backoffice/articles/#{@article.id}/edit"
    patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { tags: tags } }
  end

  def test_checkboxes_save_the_list_and_keep_targets_the_editor_cannot_see
    EssentialFixtures::Policy.hidden_tags = [ "Secret" ]
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/edit"
      group = css_select("div.raa-references[role=group]").first
      assert_select "span.raa-label##{group['aria-labelledby']}", text: "Tags"
      assert_select "input[type=checkbox][name='record[tags][]'][value='#{@ruby.id}']:not([checked])"
      assert_select "input[type=checkbox][name='record[tags][]'][value='#{@secret.id}']", count: 0
      refute_includes response.body, "Secret"
      before = RailsAiAdmin::RecordVersion.of(@article.reload)
      edit([ "", @ruby.id.to_s, @rails.id.to_s ])
      assert_response :see_other
      assert_equal %w[Rails Ruby Secret], @article.reload.tags.order(:name).pluck(:name)
      assert_operator RailsAiAdmin::RecordVersion.of(@article), :>, before, "a changed list touches the record"
      assert_equal [ "tags" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields

      get "/backoffice/articles/#{@article.id}"
      assert_select "dd a[href='/backoffice/tags/#{@ruby.id}']", text: "Ruby"
      assert_select "dd", text: /Tag ##{@secret.id}/

      edit([ "" ])
      assert_response :see_other
      assert_equal [ "Secret" ], @article.reload.tags.pluck(:name), "clearing keeps hidden targets"
    end
  end

  def test_unavailable_targets_are_refused_and_an_unchanged_list_writes_nothing
    with_essential_resources do
      edit([ @foreign.id.to_s ])
      assert_response :unprocessable_content
      assert_select "p.raa-field-error", text: "is not an available choice"
      edit([ "not a key!" ])
      assert_response :unprocessable_content
      assert_equal [ "Secret" ], @article.reload.tags.pluck(:name)
      version = RailsAiAdmin::RecordVersion.of(@article)
      edit([ "", @secret.id.to_s ])
      assert_response :see_other
      assert_equal version, RailsAiAdmin::RecordVersion.of(@article.reload)
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded").order(:id).last.changed_fields
    end
  end

  def test_has_one_panel_shows_the_single_child
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}"
      assert_select "section.raa-association h2", text: "Summary"
      assert_select "section.raa-association p", text: "No records."
      Summary.create!(account_id: 1, article: @article, text: "Short version")
      get "/backoffice/articles/#{@article.id}"
      summary = Summary.last
      assert_select "section.raa-association p a[href='/backoffice/summaries/#{summary.id}']", text: "Short version"
      assert_select "section.raa-association ul", count: 0
    end
  end

  def test_a_list_change_elsewhere_conflicts_with_an_open_form
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/edit"
      stale = intent
      edit([ "", @ruby.id.to_s ])
      assert_response :see_other
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: stale, record: { tags: [ "", @rails.id.to_s ] } }
      assert_response :conflict
      assert_equal %w[Ruby], @article.reload.tags.pluck(:name)
    end
  end
end
