# frozen_string_literal: true

require "test_helper"
require "support/essentials"
require "minitest/mock"

# Models without lock_version carry their version in updated_at.
class RecordVersionTest < Minitest::Test
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @runner = RailsAiAdmin::Operations::Runner.new
  end

  def prepare(resource, operation: :update, version: RailsAiAdmin::RecordVersion.of(@article))
    @runner.prepare(context: context, resource: resource, operation: operation, target_id: @article.id, expected_version: version)
  end

  def test_strategy_prefers_lock_version_then_updated_at
    assert_equal :lock_version, RailsAiAdmin::RecordVersion.strategy(Customer)
    assert_equal :updated_at, RailsAiAdmin::RecordVersion.strategy(Article)
    Article.stub(:record_timestamps, false) { assert_nil RailsAiAdmin::RecordVersion.strategy(Article) }
    expected = (@article.updated_at.to_r * 1_000_000).to_i
    assert_equal expected, RailsAiAdmin::RecordVersion.of(@article)
    @article.updated_at = nil
    assert_equal 0, RailsAiAdmin::RecordVersion.of(@article)
  end

  def test_update_and_destroy_work_without_lock_version
    with_essential_resources do |registry|
      resource = registry.fetch(:articles)
      result = @runner.execute(context: context, intent_ref: prepare(resource).id, input: { "title" => "Second" }, human_confirmed: true)
      assert result.success?, result.code
      assert_equal "Second", @article.reload.title
      assert_equal [ "title" ], RailsAiAdmin::AuditEvent.find(result.audit_ref).changed_fields
      result = @runner.execute(context: context, intent_ref: prepare(resource, operation: :destroy).id, input: {}, human_confirmed: true)
      assert result.success?, result.code
      refute Article.exists?(@article.id)
    end
  end

  def test_a_newer_write_conflicts_through_updated_at
    with_essential_resources do |registry|
      resource = registry.fetch(:articles)
      intent = prepare(resource)
      @article.update!(title: "Someone else")
      result = @runner.execute(context: context, intent_ref: intent.id, input: { "title" => "Mine" }, human_confirmed: true)
      assert_equal "CONFLICT", result.code
      assert_equal "Someone else", @article.reload.title
      assert_raises(RailsAiAdmin::AccessDenied) { prepare(resource, version: intent.expected_version) }
    end
  end

  def test_the_version_column_cannot_be_written
    writable = Class.new(RailsAiAdmin::Resource) do
      model "Article"
      key :articles
      title :title
      fields do
        text :title
        datetime :updated_at
      end
    end
    EssentialFixtures.const_set(:WritableVersionAdmin, writable) unless EssentialFixtures.const_defined?(:WritableVersionAdmin)
    with_essential_resources(resources: %w[EssentialFixtures::WritableVersionAdmin]) do |registry|
      error = assert_raises(RailsAiAdmin::ConfigurationError) { prepare(registry.fetch(:articles)) }
      assert_includes error.message, "updated_at carries the record version"
    end
  end
end
