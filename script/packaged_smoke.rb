# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "rubygems/installer"
require "rbconfig"
require_relative "../lib/rails_ai_admin/version"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-session-sqlite")
package = File.join(root, "pkg/rails_ai_admin-#{RailsAiAdmin::VERSION}.gem")
raise "Build the gem first" unless File.file?(package)
install_dir = File.join(root, "vendor/bundle/ruby", RbConfig::CONFIG.fetch("ruby_version"))
Gem::Installer.at(package, install_dir: install_dir, ignore_dependencies: true, wrappers: false).install
FileUtils.mkdir_p(target)
FileUtils.cp_r(Dir[File.join(root, "spec_hosts/session_sqlite/*")], target)
FileUtils.mkdir_p(File.join(target, "storage"))
env = { "BUNDLE_GEMFILE" => File.join(target, "Gemfile"), "BUNDLE_PATH" => File.join(root, "vendor/bundle"), "BUNDLE_APP_CONFIG" => File.join(target, ".bundle"), "RAILS_ENV" => "test" }

def run!(env, target, *command)
  Bundler.with_unbundled_env do
    raise "Failed: #{command.join(' ')}" unless system(env, *command, chdir: target)
  end
end

# A same-version development package may have different dependency metadata.
# Resolve it afresh instead of trusting a previous smoke run's locked gemspec.
FileUtils.rm_f(File.join(target, "Gemfile.lock"))
run!(env, target, "bundle", "install", "--local")
run!(env, target, "bundle", "exec", "ruby", File.join(root, "script/support/verify_installed_package.rb"), package)
# The generator never overwrites, so remove its earlier outputs that the spec
# host does not provide itself: each run checks this package's templates.
%w[app/rails_ai_admin/admin_policy_adapter.rb test/rails_ai_admin/access_test.rb].each do |path|
  FileUtils.rm_f(File.join(target, path)) unless File.exist?(File.join(root, "spec_hosts/session_sqlite", path))
end
# The initializer and context are checked as generated, then replaced by the
# host's reviewed files below.
[ "config/initializers/rails_ai_admin.rb", "app/rails_ai_admin/admin_context.rb" ].each { |path| FileUtils.rm_f(File.join(target, path)) }
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:install", "--force")
# Generated authentication is deliberately closed; use the independent host's
# reviewed adapters only after checking the installed stub in a fresh process.
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless AdminContext.new.resolve(nil).nil?")
[ "config/initializers/rails_ai_admin.rb", "app/rails_ai_admin/admin_context.rb" ].each do |path|
  FileUtils.cp(File.join(root, "spec_hosts/session_sqlite", path), File.join(target, path))
end
run!(env, target, "bundle", "exec", "rails", "db:migrate")
run!(env, target, "bundle", "exec", "rails", "zeitwerk:check")
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:resource", "Ticket")
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless TicketAdmin.readonly?; raise unless TicketAdmin.fields.map(&:name) == [:id]; raise if RailsAiAdmin.registry.resources.include?(TicketAdmin)")
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:install", "--skip")
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.routes.url_helpers.rails_ai_admin_path == '/staff'; raise unless RailsAiAdmin.configuration.authorization_adapter == 'AdminPolicyAdapter'; raise unless Dir['db/migrate/*rails_ai_admin*.rb'].size == Dir[RailsAiAdmin::Engine.root.join('db/migrate/*.rb')].size")
run!(env, target, "bundle", "exec", "rails", "rails_ai_admin:doctor")
run!(env, target, "bundle", "exec", "rails", "test", "test/rails_ai_admin/access_test.rb")
FileUtils.rm_f(File.join(target, "app/rails_ai_admin/user_admin.rb"))
# The host's reviewed registry stays as it is; --no-register only writes the file.
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:resource", "User", "--no-register")
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless UserAdmin.readonly?; names = UserAdmin.fields.map(&:name); raise unless names.include?(:email); raise if (names & %i[password password_digest account_id security_version role]).any?; raise if RailsAiAdmin.registry.resources.include?(UserAdmin)")
run!(env, target, "bundle", "exec", "ruby", "test/acceptance_test.rb")

# Exercise every public template through standard app/views resolution in the
# copied host only. Installation itself never copies the template tree.
override_probe = File.join(root, "script/support/packaged_override_probe.rb")
begin
  run!(env, target, "bundle", "exec", "ruby", override_probe, "prepare")
  tracker = File.join(root, "script/support/override_render_tracker.rb")
  FileUtils.cp(tracker, File.join(target, "test/override_render_tracker.rb"))
  run!(env.merge("RAA_OVERRIDE_ACCEPTANCE" => "1"), target, "bundle", "exec", "ruby", "test/acceptance_test.rb")
  run!(env.merge("RAA_REQUIRE_ALL_OVERRIDE_TEMPLATES" => "1"), target, "bundle", "exec", "ruby", override_probe, "verify")
ensure
  run!(env, target, "bundle", "exec", "ruby", override_probe, "restore")
end

run!(env.merge("RAILS_ENV" => "development"), target, "bundle", "exec", "ruby", File.join(root, "script/support/packaged_custom_controller_reload_probe.rb"))

production = env.merge("RAILS_ENV" => "production")
run!(production, target, "bundle", "exec", "rails", "assets:precompile")
run!(production, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.config.eager_load; raise unless Ai.name == 'Ai'; puts 'Production eager-load passed'")
puts "Packaged session/SQLite consumer passed: #{target}"
