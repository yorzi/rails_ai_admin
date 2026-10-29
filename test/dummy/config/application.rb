# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
require "propshaft"
require "rails_ai_admin"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "synthetic-test-only-secret-" * 4
    config.hosts = [ "www.example.com", "127.0.0.1", "localhost" ]
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = false
    config.active_support.deprecation = :stderr
    config.logger = Logger.new(File.expand_path("../../../log/test.log", __dir__))
    config.session_store :cookie_store, key: "_raa_dummy_session"
  end
end
