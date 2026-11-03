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
