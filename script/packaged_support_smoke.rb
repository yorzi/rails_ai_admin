# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "rubygems/installer"
require "rbconfig"
require_relative "../lib/rails_ai_admin/version"
require_relative "support/disposable_database"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-devise-postgres")
source = File.join(root, "spec_hosts/devise_postgres")
url = ENV.fetch("RAA_HOST_B_DATABASE_URL") { abort "Set RAA_HOST_B_DATABASE_URL to a disposable PostgreSQL database ending in _test" }
DisposableDatabase.validate!(url)
package = File.join(root, "pkg/rails_ai_admin-#{RailsAiAdmin::VERSION}.gem")
raise "Build the gem first" unless File.file?(package)
install_dir = File.join(root, "vendor/bundle/ruby", RbConfig::CONFIG.fetch("ruby_version"))
Gem::Installer.at(package, install_dir: install_dir, ignore_dependencies: true, wrappers: false).install
FileUtils.mkdir_p(target)
FileUtils.cp_r(Dir[File.join(source, "*")], target)
FileUtils.mkdir_p(File.join(target, "storage"))
env = { "BUNDLE_GEMFILE" => File.join(target, "Gemfile"), "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
  "BUNDLE_APP_CONFIG" => File.join(target, ".bundle"), "RAILS_ENV" => "test", "RAA_HOST_B_DATABASE_URL" => url,
  "RAA_ASSET_PIPELINE" => ENV.fetch("RAA_ASSET_PIPELINE", "propshaft") }

def run!(env, target, *command)
  Bundler.with_unbundled_env { raise "Failed command: #{command.first(4).join(' ')}" unless system(env, *command, chdir: target) }
end

run!(env, target, "bundle", "install", "--local")
unless Dir[File.join(target, "db/migrate/*create_ruby_llm_records.rb")].any?
  run!(env, target, "bundle", "exec", "rails", "generate", "ruby_llm:install", "chat:ProductChat", "message:ProductMessage", "--skip-active-storage", "--force")
end
FileUtils.rm_f(File.join(target, "config/initializers/ruby_llm.rb"))
%w[product_chat product_message].each { |name| FileUtils.cp(File.join(source, "app/models/#{name}.rb"), File.join(target, "app/models/#{name}.rb")) }
# Re-run the released installer against the host's existing custom named mount.
# 1.0.2 must preserve the route; do not restore it to hide a regression.
routes_file = File.join(target, "config/routes.rb")
routes_before = File.binread(routes_file)
run!(env, target, "bundle", "exec", "rails", "generate", "rails_tool_views:install", "--force")
raise "Dependency installer changed the existing custom mount" unless File.binread(routes_file) == routes_before
FileUtils.rm_f(File.join(target, "config/initializers/rails_tool_views.rb"))
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless Gem.loaded_specs.fetch('rails_tool_views').version.to_s == '1.0.2'; raise unless Rails.application.routes.url_helpers.rails_tool_views_path == '/product_surfaces'")
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:install", "--force")
run!(env, target, "bundle", "exec", "rails", "runner", "raise unless AdminContext.new.resolve(nil).nil?")
[ "config/initializers/rails_ai_admin.rb", "app/rails_ai_admin/admin_context.rb" ].each do |path|
  FileUtils.cp(File.join(source, path), File.join(target, path))
end
run!(env, target, "bundle", "exec", "rails", "db:migrate")
run!(env, target, "bundle", "exec", "rails", "zeitwerk:check")
run!(env, target, "bundle", "exec", "rails", "rails_ai_admin:doctor")
run!(env, target, "bundle", "exec", "rails", "test", "test/rails_ai_admin/access_test.rb")
FileUtils.rm_f(File.join(target, "app/rails_ai_admin/staff_user_admin.rb"))
run!(env, target, "bundle", "exec", "rails", "generate", "rails_ai_admin:resource", "StaffUser")
run!(env, target, "bundle", "exec", "rails", "runner", "source = Rails.root.join('app/rails_ai_admin/staff_user_admin.rb').read; raise unless source.include?('# text :email'); raise if source.match?(/password|security_version|role/); raise unless StaffUserAdmin.readonly? && StaffUserAdmin.fields.map(&:name) == [:id]; raise if RailsAiAdmin.registry.resources.include?(StaffUserAdmin)")
run!(env, target, "bundle", "exec", "ruby", "test/acceptance_test.rb")

# Exercise every public template through standard app/views resolution in the
# copied host only. Installation itself never copies the template tree.
override_probe = File.join(root, "script/support/packaged_override_probe.rb")
begin
  run!(env, target, "bundle", "exec", "ruby", override_probe, "prepare")
  tracker = File.join(root, "script/support/override_render_tracker.rb")
  FileUtils.cp(tracker, File.join(target, "test/override_render_tracker.rb"))
  run!(env.merge("RAA_OVERRIDE_ACCEPTANCE" => "1"), target, "bundle", "exec", "ruby", "test/acceptance_test.rb")
  run!(env, target, "bundle", "exec", "ruby", override_probe, "verify")
ensure
  run!(env, target, "bundle", "exec", "ruby", override_probe, "restore")
end

npm = [ "npm", "ci", "--ignore-scripts" ]
npm += [ "--offline", "--cache", ENV.fetch("RAA_NPM_CACHE", "/tmp/raa-npm-cache") ] if ENV["RAA_NPM_OFFLINE"] == "1"
run!(env, target, *npm)
production = env.merge("RAILS_ENV" => "production", "SKIP_YARN_INSTALL" => "1")
run!(production, target, "bundle", "exec", "rails", "assets:precompile")
run!(production, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.config.eager_load; raise unless Ai.name == 'Ai'; puts 'Support consumer production eager load passed'")
puts "Packaged Devise/Pundit/PostgreSQL consumer passed (#{env.fetch('RAA_ASSET_PIPELINE')})"
