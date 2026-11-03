# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../script/support/release_check"

class ReleaseCheckTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def statuses(check) = check.checks.to_h { |entry| [ entry.name, entry.status ] }

  def test_the_development_tree_is_consistent_and_publishing_stays_blocked
    check = ReleaseCheck.new(ROOT)
    assert_empty check.errors.map(&:message)
    result = statuses(check)
    assert_equal :closed, result.fetch("publish_gate")
    %w[version host_pins docs_config changelog package_files metadata].each { |name| assert_equal :ok, result.fetch(name), name }
  end

  def test_a_release_version_requires_every_synchronized_value_and_owner_approval
    check = ReleaseCheck.new(ROOT)
    check.define_singleton_method(:version) { "0.2.0" }
    result = statuses(check)
    %w[host_pins docs_config changelog publish_gate].each { |name| assert_equal :error, result.fetch(name), name }
    assert_equal :ok, result.fetch("package_files")
    assert_match(/owner/, check.checks.find { |entry| entry.name == "publish_gate" }.message)
  end

  def test_an_invalid_version_is_an_error
    check = ReleaseCheck.new(ROOT)
    check.define_singleton_method(:version) { "not a version" }
    assert_equal :error, statuses(check).fetch("version")
  end
end
