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
  {
    check: "Check release readiness, including owner approval to publish",
    check_candidate: "Check candidate metadata and package with publishing still closed"
  }.each do |name, description|
    desc description
    task name do
      require_relative "script/support/release_check"
      checks = ReleaseCheck.new(__dir__, candidate: name == :check_candidate).checks
      checks.each { |check| puts format("%-14s %-7s %s", check.name, check.status, check.message) }
      errors = checks.count { |check| check.status == :error }
      abort "Release check failed: #{errors} error(s)" if errors.positive?
    end
  end
end
