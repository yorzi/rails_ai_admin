# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "tmpdir"
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

  def test_approved_alpha_beta_rc_and_stable_versions_use_release_metadata
    %w[0.1.0.alpha1 0.1.0.beta1 1.0.0.rc1 1.0.0].each do |version|
      with_version_fixture(version, released: true, heading: "#{version} (2026-11-06)") do |check|
        %i[version_check host_pins_check docs_config_check changelog_check].each do |name|
          assert_equal :ok, check.send(name).status, "#{version}: #{name}"
        end
        assert_equal :review, check.send(:publish_gate_check).status
        # Owner approval is required even for a published prerelease.
        check_spec = Gem::Specification.load(File.join(check.instance_variable_get(:@root), "rails_ai_admin.gemspec"))
        check_spec.metadata["allowed_push_host"] = ReleaseCheck::BLOCKED_PUSH_HOST
        Gem::Specification.stub(:load, check_spec) do
          assert_equal :error, check.send(:publish_gate_check).status
        end
      end
    end
  end

  def test_development_builds_cannot_open_publishing_or_use_release_metadata
    with_version_fixture("0.1.0.dev", released: false, heading: "Unreleased") do |check|
      assert_equal :ok, check.send(:docs_config_check).status
      assert_equal :ok, check.send(:changelog_check).status
      assert_equal :error, check.send(:publish_gate_check).status
    end
    with_version_fixture("0.1.0.alpha1", released: false, heading: "Unreleased") do |check|
      assert_equal :error, check.send(:docs_config_check).status
      assert_equal :error, check.send(:changelog_check).status
    end
  end

  private

  def with_version_fixture(version, released:, heading:)
    Dir.mktmpdir("raa-release-check") do |root|
      paths = [ "lib/rails_ai_admin", "docs/site", "spec_hosts/session_sqlite", "spec_hosts/devise_postgres" ]
      paths.each { |path| FileUtils.mkdir_p(File.join(root, path)) }
      File.write(File.join(root, "lib/rails_ai_admin/version.rb"), %(VERSION = "#{version}"\n))
      File.write(File.join(root, "docs/site/_config.yml"), { "version" => version, "released" => released }.to_yaml)
      File.write(File.join(root, "CHANGELOG.md"), "# Changes\n\n## #{heading}\n")
      ReleaseCheck::HOST_GEMFILES.each { |path| File.write(File.join(root, path), %(gem "rails_ai_admin", "#{version}"\n)) }
      File.write(File.join(root, "rails_ai_admin.gemspec"), <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "rails_ai_admin"
          spec.version = "#{version}"
          spec.metadata["allowed_push_host"] = "https://rubygems.org"
        end
      RUBY
      yield ReleaseCheck.new(root)
    end
  end
end
