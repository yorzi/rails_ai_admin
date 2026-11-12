# frozen_string_literal: true

require "rails/generators"
require_relative "../engine_migrations"

module RailsAiAdmin
  module Generators
    # Adds opt-in admin Chat storage and a closed provider adapter. Nothing is
    # enabled until the host sets `config.assistant = true` and returns a
    # RubyLLM::Context from the adapter.
    class AssistantGenerator < Rails::Generators::Base
      include EngineMigrations
      source_root File.expand_path("templates", __dir__)

      def install
        copy_engine_migrations("db/assistant_migrate")
        target = "app/rails_ai_admin/admin_assistant.rb"
        template "admin_assistant.rb", target unless File.exist?(File.join(destination_root, target))
        say "The assistant stays unavailable: AdminAssistant#llm_context returns nil, and no resource grants assistant?."
        say "Add ruby_llm (#{Configuration::OPTIONAL_GEMS.fetch('ruby_llm').fetch(:requirement).join(', ')}) to the Gemfile, run db:migrate, then set config.assistant = true, config.assistant_adapter = \"AdminAssistant\" and config.assistant_model."
        say "Schedule rails_ai_admin:assistant:scan to recover lost jobs. Guide: #{GUIDES}/_advanced/admin-assistant.md"
      end
    end
  end
end
