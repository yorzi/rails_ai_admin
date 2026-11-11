# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/collections"
require "rails_ai_admin/doctor"
require "rails_ai_admin/prune"

# Phase 2 contract regressions: boot checks, queue visibility and pruning.
class FlowRegressionsContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include CollectionContractHelpers

  def setup = reset_database

  def with_tool_views_parent(name)
    previous = RailsToolViews.configuration.parent_controller
    RailsToolViews.configuration.parent_controller = name
    yield
  ensure
    RailsToolViews.configuration.parent_controller = previous
  end

  def surfaces_configuration
    config = RailsAiAdmin::Configuration.new
    config.surfaces = true
    config.resources = []
    config
  end

  def test_raa_009_a_missing_surfaces_parent_controller_fails_boot_with_a_named_setting
    with_tool_views_parent("::MissingHostApplicationController") do
      error = assert_raises(RailsAiAdmin::ConfigurationError) { surfaces_configuration.finalize! }
      assert_includes error.message, "parent_controller"
      assert_includes error.message, "MissingHostApplicationController"
      check = RailsAiAdmin::Doctor.new(configuration: RailsAiAdmin.configuration, application: nil).surface_check
      assert_equal :error, check.status
      assert_includes check.message, "parent_controller"
    end
    with_tool_views_parent("::ActiveRecord::Base") do
      assert_raises(RailsAiAdmin::ConfigurationError) { surfaces_configuration.finalize! }
    end
    with_tool_views_parent("ActionController::Base") { assert surfaces_configuration.finalize! }
    # Without Surfaces the setting is the host's business.
    with_tool_views_parent("::MissingHostApplicationController") { assert RailsAiAdmin::Configuration.new.finalize! }
  end

  # The gemspec no longer depends on rails_tool_views or ruby_llm; a feature
  # that needs one checks the host-loaded version at boot (RAA-026).
  def test_raa_026_optional_gems_are_not_runtime_dependencies_and_boot_checks_their_range
    names = Gem::Specification.load(File.expand_path("../../rails_ai_admin.gemspec", __dir__)).runtime_dependencies.map(&:name)
    assert_empty names & RailsAiAdmin::Configuration::OPTIONAL_GEMS.keys
    assert_nil RailsAiAdmin::Configuration.optional_gem_problem("rails_tool_views", "surfaces")
    assert_nil RailsAiAdmin::Configuration.optional_gem_problem("ruby_llm", "assistant")
    old = RailsAiAdmin::Configuration.optional_gem_problem("ruby_llm", "assistant", version: "2.0.0")
    assert_equal "assistant needs ruby_llm >= 2.1.1, < 3 in the host Gemfile (2.0.0 is loaded)", old
    assert_includes RailsAiAdmin::Configuration.optional_gem_problem("ruby_llm", "assistant", version: "3.0.0"), "3.0.0 is loaded"
    assert_equal "surfaces needs rails_tool_views ~> 1.0.2 in the host Gemfile (it is not loaded)",
      RailsAiAdmin::Configuration.optional_gem_problem("rails_tool_views", "surfaces", version: nil)
    with_tool_views_parent("ActionController::Base") do
      RailsAiAdmin::Configuration.stub(:optional_gem_problem, ->(name, feature) { "#{feature} needs #{name}" }) do
        error = assert_raises(RailsAiAdmin::ConfigurationError) { surfaces_configuration.finalize! }
        assert_equal "surfaces needs rails_tool_views", error.message
      end
    end
  end

  def test_raa_020_queue_name_is_configurable_and_validated
    assert_equal "rails_ai_admin", RailsAiAdmin::Configuration.new.queue_name
    config = RailsAiAdmin::Configuration.new
    config.queue_name = :admin_work
    config.finalize!
    assert_equal "admin_work", config.queue_name
    bad = RailsAiAdmin::Configuration.new
    bad.queue_name = "has spaces"
    assert_raises(RailsAiAdmin::ConfigurationError) { bad.finalize! }
    custom = RailsAiAdmin.configuration.dup
    custom.queue_name = "admin_work"
    RailsAiAdmin.stub(:configuration, custom) do
      assert_equal "admin_work", RailsAiAdmin::Collections::ExecutionJob.new.queue_name
    end
    assert_equal "rails_ai_admin", RailsAiAdmin::Collections::ExecutionJob.new.queue_name
  end

  def test_raa_020_queued_collection_work_reports_its_age_and_doctor_flags_a_backlog
    with_collection do
      second = Customer.create!(account_id: 1, name: "Second")
      proposed = proposal(selection_ref: selection([ @customer.id, second.id ]).selection_ref)
      admitted = admit(proposed)
      assert_includes %w[OK QUEUED], admitted.code, admitted.inspect
      proposal = proposed
      snapshot = RailsAiAdmin::Collections::Queries.new.fetch(context: context, job_ref: proposal.intent.id)
      assert_in_delta Time.current, snapshot.waiting_since, 5
      assert_equal :ok, RailsAiAdmin::Doctor.new(application: nil).send(:backlog_check).status
      travel 20.minutes do
        check = RailsAiAdmin::Doctor.new(application: nil).send(:backlog_check)
        assert_equal :review, check.status
        assert_includes check.message, "2 collection items"
        assert_includes check.message, "\"rails_ai_admin\" queue"
      end
      RailsAiAdmin::Collections::Dispatcher.new.run(proposal.intent.id)
      assert_nil RailsAiAdmin::Collections::Queries.new.fetch(context: context, job_ref: proposal.intent.id).waiting_since
    end
  end

  def test_raa_005_prune_removes_only_expired_unused_intents_and_selections
    runner = RailsAiAdmin::Operations::Runner.new
    old = runner.prepare(context: context, resource: TestResource, operation: :update, target_id: @customer.id, expected_version: 0)
    fresh = runner.prepare(context: context, resource: TestResource, operation: :update, target_id: @customer.id, expected_version: 0)
    used = runner.prepare(context: context, resource: TestResource, operation: :update, target_id: @customer.id, expected_version: 0)
    assert runner.execute(context: context, intent_ref: used.id, input: { "name" => "Used" }, human_confirmed: true).success?
    old.update_columns(expires_at: 8.days.ago)
    used.reload.update_columns(expires_at: 8.days.ago)
    with_collection do
      expired = selection([ @customer.id ])
      RailsAiAdmin::Selection.where(id: expired.selection_ref).update_all(expires_at: 8.days.ago)
      kept = selection([ @customer.id ])
      result = RailsAiAdmin::Prune.new.call
      assert_equal 1, result.intents
      assert_equal 1, result.selections
      assert RailsAiAdmin::Selection.exists?(kept.selection_ref)
      assert_equal 1, RailsAiAdmin::SelectionItem.count
    end
    refute RailsAiAdmin::OperationRun.exists?(old.id)
    assert RailsAiAdmin::OperationRun.exists?(fresh.id)
    assert RailsAiAdmin::OperationRun.exists?(used.id), "a succeeded receipt is never pruned"
    assert_equal 1, RailsAiAdmin::AuditEvent.count
    assert_equal 0, RailsAiAdmin::Prune.new(older_than: 30.days).call.intents
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Prune.new(older_than: -1.day) }
  end
end
