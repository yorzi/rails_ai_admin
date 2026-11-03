# frozen_string_literal: true

require "bundler/setup"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

task default: :test

desc "Build the local gem (does not publish)"
task :build do
  require_relative "lib/rails_ai_admin/version"
  mkdir_p "pkg"
  sh "gem build rails_ai_admin.gemspec --output pkg/rails_ai_admin-#{RailsAiAdmin::VERSION}.gem"
end

namespace :release do
  desc "Check release readiness without building, tagging or publishing"
  task :check do
    require_relative "script/support/release_check"
    report = ReleaseCheck.new(__dir__)
    checks = report.checks
    checks.each { |check| puts format("%-14s %-7s %s", check.name, check.status, check.message) }
    abort "Release check failed: #{checks.count { |check| check.status == :error }} error(s)" if checks.any? { |check| check.status == :error }
  end
end
