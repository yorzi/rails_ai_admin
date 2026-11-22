# frozen_string_literal: true

require "support/database"
require "fileutils"
FileUtils.mkdir_p(File.expand_path("../../log", __dir__))

class TestContext
  def resolve(controller)
    id = controller.session[:actor_id]
    return unless id
    RailsAiAdmin::Context.new(actor: TestActor.new(id), tenant: TestTenant.new(1), security_version: "1")
  end
end
RailsAiAdmin.configuration.context_adapter = "TestContext"
RailsAiAdmin.configuration.surfaces = true
# Draws the assistant routes; tests stub a full configuration per case.
RailsAiAdmin.configuration.assistant = true
RailsAiAdmin.configuration.assistant_adapter = "TestAssistant"
RailsAiAdmin.configuration.assistant_model = "gpt-4.1-mini"
RailsAiAdmin.configuration.assistant_provider = "openai"
RailsAiAdmin.configuration.assistant_protocol = "chat_completions"
# Draws the MCP routes; tests stub a full configuration per case.
RailsAiAdmin.configuration.mcp = true
require_relative "../dummy/config/application"
Rails.application.initialize!
# Draw engine routes while assistant, surfaces and MCP are enabled above, so
# random test order cannot lazily draw them under a stubbed configuration.
Rails.application.reload_routes_unless_loaded if Rails.application.respond_to?(:reload_routes_unless_loaded)
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(File.expand_path("../../db/migrate", __dir__)).migrate
ActiveRecord::MigrationContext.new(RailsToolViews::Engine.root.join("db/migrate").to_s).migrate
ActiveRecord::MigrationContext.new(Gem.loaded_specs.fetch("activestorage").full_gem_path + "/db/migrate").migrate
ActiveRecord::MigrationContext.new(Gem.loaded_specs.fetch("actiontext").full_gem_path + "/db/migrate").migrate
# The application does not have a database.yml; preserve the explicit test DB.
require "rails/test_help"
