# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "rubygems/installer"
require "rbconfig"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-session-sqlite")
package = File.join(root, "pkg/rails_ai_admin-0.1.0.dev.gem")
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

run!(env, target, "bundle", "install", "--local")
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
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.routes.url_helpers.rails_ai_admin_path == '/staff'; raise unless RailsAiAdmin.configuration.authorization_adapter == 'AdminPolicyAdapter'; raise unless Dir['db/migrate/*rails_ai_admin*.rb'].size == 2")
run!(env, target, "bundle", "exec", "rails", "rails_ai_admin:doctor")
run!(env, target, "bundle", "exec", "ruby", "test/acceptance_test.rb")
production = env.merge("RAILS_ENV" => "production")
run!(production, target, "bundle", "exec", "rails", "assets:precompile")
run!(production, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.config.eager_load; raise unless Ai.name == 'Ai'; puts 'Production eager-load passed'")
puts "Packaged session/SQLite consumer passed: #{target}"
