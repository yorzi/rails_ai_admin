# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# Bulk delete over a fixed selection, through the native destroy operation.
class BulkDestroyIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @second = Article.create!(account_id: 1, title: "Second")
    @third = Article.create!(account_id: 1, title: "Third")
    post "/test/sign_in/1"
  end

  def select(*records)
    post "/backoffice/articles/selections", params: { target_ids: records.map(&:id) }
    assert_response :see_other
    URI(response.location).path
  end

  def test_selected_records_are_deleted_one_by_one_and_audited
    with_essential_resources do
      path = select(@article, @second)
      get path
      assert_select "a[href='#{path}/destroy']", text: "Delete the 2 selected records"
      get "#{path}/destroy"
      assert_response :success
      assert_select "h1", text: "Delete selected records"
      assert_select "li", text: "First"
      assert_select "li", text: "Second"
      digest = css_select("input[name=manifest_digest]").first["value"]
      assert_equal 0, RailsAiAdmin::AuditEvent.count, "the review page writes nothing"
      post "#{path}/destroy", params: { manifest_digest: digest }
      assert_response :see_other
      assert_equal "/backoffice/articles", URI(response.location).path
      follow_redirect!
      assert_select "[role=status], .raa-notice", text: /Deleted 2 records/
      assert_equal [ "Third" ], Article.where(account_id: 1).pluck(:title)
      events = RailsAiAdmin::AuditEvent.where(operation: "destroy", status: "succeeded")
      assert_equal [ @article.id.to_s, @second.id.to_s ].sort, events.pluck(:record_id).sort
    end
  end

  def test_records_that_cannot_be_deleted_are_kept_and_reported
    @second.update!(title: "Locked")
    EssentialFixtures::Policy.undeletable = [ "Third" ]
    with_essential_resources do
      path = select(@article, @second, @third)
      get "#{path}/destroy"
      assert_select "li", count: 2
      assert_select "p.raa-notice", text: "1 selected record cannot be deleted by you and will be kept."
      digest = css_select("input[name=manifest_digest]").first["value"]
      post "#{path}/destroy", params: { manifest_digest: digest }
      assert_response :success
      assert_select "p[role=status]", text: "Deleted 1 record."
      assert_select "td a", text: "Locked"
      assert_select "td", text: /still in use/
      assert_equal %w[Locked Third], Article.where(account_id: 1).order(:title).pluck(:title)
    end
  end

  def test_a_changed_selection_wrong_digest_or_missing_grants_delete_nothing
    with_essential_resources do
      path = select(@article, @second)
      get "#{path}/destroy"
      digest = css_select("input[name=manifest_digest]").first["value"]
      post "#{path}/destroy", params: { manifest_digest: "0" * 64 }
      assert_response :conflict
      post "#{path}/destroy", params: { manifest_digest: "not hex" }
      assert_response :unprocessable_content
      @second.update!(title: "Edited after selecting")
      post "#{path}/destroy", params: { manifest_digest: digest }
      assert_response :conflict
      assert_equal 3, Article.where(account_id: 1).count
    end
    post "/test/sign_in/2"
    with_essential_resources do
      post "/backoffice/articles/selections", params: { target_ids: [ @third.id ] }
      path = URI(response.location).path
      get path
      assert_select "a[href$='/destroy']", count: 0
      # Nothing deletable: back to the selection with a reason, not an error.
      get "#{path}/destroy"
      assert_response :see_other
      assert_equal path, URI(response.location).path
      follow_redirect!
      assert_select "[role=status], .raa-notice", text: /None of the selected records can be deleted by you/
    end
    post "/test/sign_in/1"
    with_essential_resources(resources: %w[EssentialFixtures::ReadonlyArticleAdmin]) do
      post "/backoffice/articles/selections", params: { target_ids: [ @third.id ] }
      path = URI(response.location).path
      get path
      assert_select "a[href$='/destroy']", count: 0
      get "#{path}/destroy"
      assert_response :not_found
    end
    assert_equal 3, Article.where(account_id: 1).count
  end

  def test_the_list_offers_delete_selected_in_one_step_through_the_review_page
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "form#raa-selection button[name=then][value=destroy]", text: "Delete selected"
      assert_select "form#raa-selection button:not([name])", text: "Review selection"
      post "/backoffice/articles/selections", params: { target_ids: [ @article.id, @third.id ], then: "destroy" }
      assert_response :see_other
      assert_match %r{\A/backoffice/selections/[0-9a-f-]{36}/destroy\z}, URI(response.location).path
      follow_redirect!
      assert_select "h1", text: "Delete selected records"
      assert_select "a[href='/backoffice/articles']", text: "Cancel", minimum: 1
      assert_equal 3, Article.where(account_id: 1).count, "the one-step button only opens the review"
      # Unknown next steps fall back to the selection page.
      [ "operation:missing", "operation:Bad", "drop", "" ].each do |step|
        post "/backoffice/articles/selections", params: { target_ids: [ @article.id ], then: step }
        assert_match %r{\A/backoffice/selections/[0-9a-f-]{36}\z}, URI(response.location).path, step
      end
    end
    with_essential_resources(resources: %w[EssentialFixtures::ReadonlyArticleAdmin]) do
      get "/backoffice/articles"
      assert_select "button[name=then][value=destroy]", count: 0
      post "/backoffice/articles/selections", params: { target_ids: [ @article.id ], then: "destroy" }
      assert_match %r{\A/backoffice/selections/[0-9a-f-]{36}\z}, URI(response.location).path
    end
  end

  def test_all_matching_records_across_pages_can_be_selected_up_to_the_limit
    30.times { |index| Article.create!(account_id: 1, title: "Bulk #{index.to_s.rjust(2, "0")}") }
    Article.create!(account_id: 2, title: "Bulk foreign")
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "nav.raa-pagination"
      assert_select "form#raa-selection input#raa-all-matching[type=checkbox][name=all_matching][data-count='33']"
      assert_select "label[for=raa-all-matching]", text: "All 33 matching records"
      get "/backoffice/articles", params: { q: "Bulk" }
      assert_select "input#raa-all-matching[data-count='30']"
      post "/backoffice/articles/selections", params: { all_matching: "1", then: "destroy", return_to: { q: "Bulk" } }
      assert_response :see_other
      follow_redirect!
      assert_select "h1", text: "Delete selected records"
      assert_select "li", count: 30
      assert_equal 30, RailsAiAdmin::Selection.last.item_count
      assert_equal Article.where(account_id: 1).where("title LIKE 'Bulk%'").pluck(:id).map(&:to_s).sort,
        RailsAiAdmin::SelectionItem.where(selection_id: RailsAiAdmin::Selection.last.id).pluck(:target_id).sort
      80.times { |index| Article.create!(account_id: 1, title: "More #{index}") }
      get "/backoffice/articles"
      assert_select "input#raa-all-matching", count: 0
      assert_select ".raa-selection-bar .raa-field-help", text: /up to 100 records/
      post "/backoffice/articles/selections", params: { all_matching: "1" }
      assert_response :see_other
      follow_redirect!
      assert_select ".raa-notice", text: /More than 100 records match/
    end
  end
end
