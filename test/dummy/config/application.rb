# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
# Loaded as a host with uploads would; file fields need Active Storage.
require "active_storage/engine"
require "action_text/engine"
require "propshaft"
require "rails_ai_admin"
# Loaded as a host would; the dummy app deliberately configures no global
# rails_tool_views resolver, so admin Surfaces must not depend on one.
require "rails_tool_views"
# Loaded as a host would for admin Chat; the dummy app configures no global
# RubyLLM credentials, so the assistant must use its own provider context.
require "ruby_llm"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.enable_reloading = false
    config.secret_key_base = "synthetic-test-only-secret-" * 4
    config.hosts = [ "www.example.com", "127.0.0.1", "localhost" ]
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = false
    config.active_support.deprecation = :stderr
    config.logger = Logger.new(File.expand_path("../../../log/test.log", __dir__))
    config.session_store :cookie_store, key: "_raa_dummy_session"
    # Every framework string must exist in config/locales (I18n release gate).
    config.i18n.raise_on_missing_translations = true
    config.active_storage.service = :test
    config.active_job.queue_adapter = :test
  end
end
