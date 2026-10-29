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
require_relative "../dummy/config/application"
Rails.application.initialize!
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(File.expand_path("../../db/migrate", __dir__)).migrate
# The application does not have a database.yml; preserve the explicit test DB.
require "rails/test_help"
