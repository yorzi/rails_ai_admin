# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module RailsAiAdmin
  module Generators
    # Installs conventional tables and a deliberately closed host context.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        [ Time.now.utc.strftime("%Y%m%d%H%M%S"), format("%014d", current_migration_number(dirname) + 1) ].max
      end

      def install
        Engine.root.join("db/migrate").glob("*.rb").sort.each do |source|
          stem = source.basename.to_s.sub(/\A\d+_/, "")
          migration_template source.to_s, "db/migrate/#{stem}"
        end
        template "initializer.rb", "config/initializers/rails_ai_admin.rb"
        template "admin_context.rb", "app/rails_ai_admin/admin_context.rb"
        routes_file = File.join(destination_root, "config/routes.rb")
        existing_mount = File.exist?(routes_file) && File.read(routes_file).match?(/^\s*mount\s+RailsAiAdmin::Engine\b/)
        route 'mount RailsAiAdmin::Engine => "/admin", as: :rails_ai_admin' unless existing_mount
        say "Access remains closed. Implement AdminContext and an explicit policy adapter; then run db:migrate and rails_ai_admin:doctor."
      end
    end
  end
end
