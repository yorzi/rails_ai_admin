# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module RailsAiAdmin
  module Generators
    # Adds opt-in admin Chat storage and a closed provider adapter. Nothing is
    # enabled until the host sets `config.assistant = true` and returns a
    # RubyLLM::Context from the adapter.
    class AssistantGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        [ Time.now.utc.strftime("%Y%m%d%H%M%S"), format("%014d", current_migration_number(dirname) + 1) ].max
      end

      def install
        Engine.root.join("db/assistant_migrate").glob("*.rb").sort.each do |source|
          migration_template source.to_s, "db/migrate/#{source.basename.to_s.sub(/\A\d+_/, '')}"
        end
        target = "app/rails_ai_admin/admin_assistant.rb"
        template "admin_assistant.rb", target unless File.exist?(File.join(destination_root, target))
        say "The assistant stays unavailable: AdminAssistant#llm_context returns nil, and no resource grants assistant?."
        say "Add ruby_llm to the Gemfile, run db:migrate, then set config.assistant = true, config.assistant_adapter = \"AdminAssistant\" and config.assistant_model."
        say "Schedule rails_ai_admin:assistant:scan to recover lost jobs. See docs/site/_advanced/admin-assistant.md."
      end
    end
  end
end
