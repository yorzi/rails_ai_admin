# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require_relative "engine_mounts"

module RailsAiAdmin
  module Generators
    # Installs conventional tables and a deliberately closed host context.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def initialize(args = [], options = {}, config = {})
        @host_application = config.fetch(:application) { Rails.application }
        super
      end

      def self.next_migration_number(dirname)
        [ Time.now.utc.strftime("%Y%m%d%H%M%S"), format("%014d", current_migration_number(dirname) + 1) ].max
      end

      def install
        unless @host_application && @host_application.root.realpath == Pathname.new(destination_root).realpath
          raise Rails::Generators::Error, "Run install inside the target Rails application so its actual routes can be checked. No files were changed."
        end
        mounts = EngineMounts.names(@host_application.routes)
        if mounts.empty? && @host_application.routes.named_routes.names.map(&:to_s).include?("rails_ai_admin")
          raise Rails::Generators::Error, "The rails_ai_admin route name belongs to another endpoint. Resolve the conflict before installation. No files were changed."
        end
        if mounts.any? && mounts != [ "rails_ai_admin" ]
          raise Rails::Generators::Error, "Use one RailsAiAdmin::Engine mount whose final helper is rails_ai_admin. Custom paths are supported; other aliases, name prefixes, dynamic parameters and multiple mounts require review. No files were changed."
        end
        %w[AdminContext AdminPolicyAdapter ExampleAdmin].each do |constant|
          target = File.join(destination_root, "app/rails_ai_admin/#{constant.underscore}.rb")
          if Object.const_defined?(constant) && !File.exist?(target)
            raise Rails::Generators::Error, "Constant #{constant} already exists outside the generated path"
          end
        end
        Engine.root.join("db/migrate").glob("*.rb").sort.each do |source|
          stem = source.basename.to_s.sub(/\A\d+_/, "")
          migration_template source.to_s, "db/migrate/#{stem}"
        end
        template "initializer.rb", "config/initializers/rails_ai_admin.rb"
        template "admin_context.rb", "app/rails_ai_admin/admin_context.rb"
        {
          "admin_policy_adapter.rb" => "app/rails_ai_admin/admin_policy_adapter.rb",
          "example_admin.rb" => "app/rails_ai_admin/example_admin.rb",
          "access_test.rb" => "test/rails_ai_admin/access_test.rb"
        }.each do |source, target|
          template source, target unless File.exist?(File.join(destination_root, target))
        end
        route 'mount RailsAiAdmin::Engine => "/admin", as: :rails_ai_admin' if mounts.empty?
        say "Access remains closed. Implement AdminContext and an explicit policy adapter; then run db:migrate and rails_ai_admin:doctor."
        say "ExampleAdmin is unregistered. Review it or generate your own resource. Run bin/rails test test/rails_ai_admin/access_test.rb."
        say "Setup documentation: #{Engine.root.join('README.md')}"
      end
    end
  end
end
