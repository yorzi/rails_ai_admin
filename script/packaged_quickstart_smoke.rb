# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "rubygems/installer"
require "rbconfig"
require "rails"
require_relative "../lib/rails_ai_admin/version"

# Exercise the documented setup against a fresh Rails app and the built gem.
# All generated files and data live in the disposable tmp host.
root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-quickstart")
package = File.join(root, "pkg/rails_ai_admin-#{RailsAiAdmin::VERSION}.gem")
raise "Build the gem first" unless File.file?(package)
install_dir = File.join(root, "vendor/bundle/ruby", RbConfig::CONFIG.fetch("ruby_version"))
Gem::Installer.at(package, install_dir: install_dir, ignore_dependencies: true, wrappers: false).install
FileUtils.rm_rf(target)
system("bundle", "exec", "rails", "new", target, "--skip-bundle", "--skip-git", "--skip-ci", "--skip-docker", "--skip-solid", "--skip-bootsnap", "--skip-system-test", "--skip-javascript", "--skip-hotwire", "--skip-thruster", "--skip-rubocop", "--skip-brakeman", "--skip-bundler-audit", exception: true)
File.write(File.join(target, "Gemfile"), <<~GEMS)
  source "https://rubygems.org"
  gem "rails", "#{Rails.version}"
  gem "rails_ai_admin", "#{RailsAiAdmin::VERSION}"
  gem "sqlite3", "~> 2.0"
  gem "propshaft", "~> 1.3"
  gem "bcrypt", "~> 3.1"
  gem "minitest", "~> 6.0"
GEMS
File.write(File.join(target, "config/routes.rb"), "Rails.application.routes.draw do\n  root to: redirect('/admin')\nend\n")
env = { "BUNDLE_GEMFILE" => File.join(target, "Gemfile"), "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
  "BUNDLE_APP_CONFIG" => File.join(target, ".bundle"), "RAILS_ENV" => "test" }
run = lambda do |*command|
  Bundler.with_unbundled_env { system(env, *command, chdir: target, exception: true) }
end
run.call("bundle", "install", "--local")
run.call("bundle", "exec", "ruby", File.join(root, "script/support/verify_installed_package.rb"), package)
run.call("bin/rails", "generate", "authentication")
run.call("bin/rails", "generate", "migration", "AddAdminToUsers", "admin:boolean")
run.call("bin/rails", "generate", "model", "Article", "title:string", "body:text")
run.call("bin/rails", "db:migrate")
run.call("bin/rails", "generate", "rails_ai_admin:install", "--full-access")
run.call("bin/rails", "db:migrate")
run.call("bin/rails", "generate", "rails_ai_admin:resource", "--all")
run.call("bin/rails", "zeitwerk:check")
FileUtils.cp(File.join(root, "script/support/quickstart_acceptance.rb"), File.join(target, "test/quickstart_acceptance_test.rb"))
run.call("bin/rails", "test", "test/quickstart_acceptance_test.rb", "test/rails_ai_admin/access_test.rb")
# A rerun must not change any reviewed generated file, even with --force.
paths = Dir[File.join(target, "app/rails_ai_admin/**/*.rb"), File.join(target, "config/initializers/rails_ai_admin.rb")]
before = paths.to_h { |path| [ path, File.binread(path) ] }
run.call("bin/rails", "generate", "rails_ai_admin:install", "--force")
run.call("bin/rails", "generate", "rails_ai_admin:resource", "--all")
raise "Rerun changed host configuration" unless before.all? { |path, content| File.binread(path) == content }
puts "Packaged quickstart passed: generated authentication, registration, CRUD, revocation and rerun preservation"
