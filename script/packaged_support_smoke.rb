# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "rubygems/installer"
require "rbconfig"
require_relative "support/disposable_database"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-devise-postgres")
source = File.join(root, "spec_hosts/devise_postgres")
url = ENV.fetch("RAA_HOST_B_DATABASE_URL") { abort "Set RAA_HOST_B_DATABASE_URL to a disposable PostgreSQL database ending in _test" }
DisposableDatabase.validate!(url)
package = File.join(root, "pkg/rails_ai_admin-0.1.0.dev.gem")
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
unless Dir[File.join(target, "db/migrate/*create_rails_tool_views.rb")].any?
  # Exercise the released installer on an existing custom product mount. Keep the
  # host's route/config as the authority, rather than modifying the dependency.
  run!(env, target, "bundle", "exec", "rails", "generate", "rails_tool_views:install", "--force")
end
FileUtils.cp(File.join(source, "config/routes.rb"), File.join(target, "config/routes.rb"))
FileUtils.rm_f(File.join(target, "config/initializers/rails_tool_views.rb"))
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
npm = [ "npm", "ci", "--ignore-scripts" ]
npm += [ "--offline", "--cache", ENV.fetch("RAA_NPM_CACHE", "/tmp/raa-npm-cache") ] if ENV["RAA_NPM_OFFLINE"] == "1"
run!(env, target, *npm)
production = env.merge("RAILS_ENV" => "production", "SKIP_YARN_INSTALL" => "1")
run!(production, target, "bundle", "exec", "rails", "assets:precompile")
run!(production, target, "bundle", "exec", "rails", "runner", "raise unless Rails.application.config.eager_load; raise unless Ai.name == 'Ai'; puts 'Support consumer production eager load passed'")
puts "Packaged Devise/Pundit/PostgreSQL consumer passed (#{env.fetch('RAA_ASSET_PIPELINE')})"
