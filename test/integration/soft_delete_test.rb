# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"
require "rails_ai_admin/doctor"

class SoftMemoAdmin < RailsAiAdmin::Resource
  model "Memo"
  key :memos
  title :name
  fields do
    id :id
    text :name, required: true, searchable: true
    integer :points
  end
  soft_delete :discarded_at
end

# Deleting a soft-delete resource hides the record; restoring brings it back.
class SoftDeleteTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    @memo = Memo.create!(account_id: 1, name: "Keep me")
    @gone = Memo.create!(account_id: 1, name: "Old memo", discarded_at: 2.days.ago)
    @foreign = Memo.create!(account_id: 2, name: "Foreign", discarded_at: 1.day.ago)
    post "/test/sign_in/1"
  end

  class MemoPolicy < TestPolicy
    def select_records?(context:, resource:) = context.actor.id == 1
  end

  def with_memos
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "SoftDeleteTest::MemoPolicy"
    registry = RailsAiAdmin::Registry.new([ "TestResource", "SoftMemoAdmin" ])
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, RailsAiAdmin::Operations::Registry.new(registry.resources)) { yield }
      end
    end
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_deleting_hides_the_record_and_restoring_brings_it_back
    with_memos do
      get "/backoffice/memos"
      assert_select "tbody .raa-row-title", text: "Keep me"
      assert_select "tbody .raa-row-title", text: "Old memo", count: 0
      assert_select ".raa-list-links a[href='/backoffice/memos/deleted']", text: "Deleted records"
      get "/backoffice/memos/#{@gone.id}"
      assert_response :not_found, "a deleted record has no page"
      get "/backoffice/memos/#{@memo.id}/confirm_destroy"
      assert_select "p", text: "Delete Keep me?"
      assert_select "p", text: /moves to Deleted records/
      delete "/backoffice/memos/#{@memo.id}", params: { intent_ref: intent }
      assert_response :see_other
      assert @memo.reload.discarded_at, "the row stays, with a deletion time"
      assert_equal 1, @memo.lock_version, "the version advanced"
      assert_equal [ "destroy", "succeeded" ], RailsAiAdmin::AuditEvent.last.slice(:operation, :status).values
      get "/backoffice/memos"
      assert_select "tbody .raa-row-title", count: 0
      get "/backoffice/memos/deleted"
      assert_response :success
      assert_select "h1", text: "Deleted Memos"
      assert_equal [ "Keep me", "Old memo" ], css_select("tbody td.raa-cell-title").map { |node| node.text.strip }, "newest first, own tenant only"
      version = css_select("input[name=expected_version]").first["value"]
      post "/backoffice/memos/deleted/#{@memo.id}/restore", params: { expected_version: version }
      assert_response :see_other
      assert_equal "/backoffice/memos/#{@memo.id}", URI(response.location).path
      follow_redirect!
      assert_select "[role=status], .raa-notice", text: /Restored the record/
      assert_nil @memo.reload.discarded_at
      event = RailsAiAdmin::AuditEvent.last
      assert_equal [ "restore", "succeeded", @memo.id.to_s ], [ event.operation, event.status, event.record_id ]
    end
  end

  def test_restore_checks_the_version_grant_and_tenant
    with_memos do
      post "/backoffice/memos/deleted/#{@gone.id}/restore", params: { expected_version: "99" }
      assert_response :see_other
      follow_redirect!
      assert_select ".raa-notice", text: /changed after this page was opened/
      assert @gone.reload.discarded_at
      post "/backoffice/memos/deleted/#{@foreign.id}/restore", params: { expected_version: @foreign.lock_version.to_s }
      assert_response :not_found
      post "/backoffice/memos/deleted/#{@memo.id}/restore", params: { expected_version: @memo.lock_version.to_s }
      assert_response :not_found, "a record that is not deleted cannot be restored"
      post "/backoffice/memos/deleted/#{@gone.id}/restore", params: { expected_version: "1.0" }
      assert_response :unprocessable_content
      post "/test/sign_in/2"
      get "/backoffice/memos/deleted"
      assert_response :not_found, "restoring is its own grant"
      get "/backoffice/memos"
      assert_select "a", text: "Deleted records", count: 0
    end
  end

  def test_bulk_delete_soft_deletes_each_record
    second = Memo.create!(account_id: 1, name: "Second")
    with_memos do
      post "/backoffice/memos/selections", params: { target_ids: [ @memo.id, second.id ], then: "destroy" }
      follow_redirect!
      assert_select "strong", text: "Delete these 2 records?"
      post "#{URI(request.url).path}", params: { manifest_digest: css_select("input[name=manifest_digest]").first["value"] }
      assert_equal 0, Memo.where(account_id: 1, discarded_at: nil).count
      assert_equal 4, Memo.count
    end
  end

  def test_resource_rules_and_doctor
    assert SoftMemoAdmin.action_enabled?(:restore)
    refute TestResource.action_enabled?(:restore)
    assert_raises(RailsAiAdmin::ConfigurationError) do
      Class.new(RailsAiAdmin::Resource) do
        model "Memo"
        title :name
        fields do
          text :name
          readonly :discarded_at, type: :datetime
        end
        soft_delete :discarded_at
      end.validate!
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { Class.new(RailsAiAdmin::Resource) { soft_delete "discarded_at" } }
    checks = RailsAiAdmin::Doctor.new(registry: RailsAiAdmin::Registry.new([ "SoftMemoAdmin" ]), application: nil).checks
    check = checks.find { |entry| entry.name == "soft_delete:memos" }
    assert_equal :review, check.status
    assert_match(/Index on discarded_at=false/, check.message)
  end
end
