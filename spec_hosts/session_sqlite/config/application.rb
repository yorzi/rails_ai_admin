require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
Bundler.require(*Rails.groups)

module SessionConsumer
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = ENV["RAILS_ENV"] == "production"
    config.secret_key_base = "synthetic-packaged-host-session-secret-" * 4
    config.hosts = [ "www.example.com", "localhost", "127.0.0.1" ]
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = true
    config.session_store :cookie_store, key: "_raa_session_consumer"
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
