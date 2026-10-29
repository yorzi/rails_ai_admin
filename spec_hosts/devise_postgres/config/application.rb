require_relative "boot"
require "rails/all"
Bundler.require(*Rails.groups)

module SupportConsumer
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = ENV["RAILS_ENV"] == "production"
    config.enable_reloading = ENV["RAILS_ENV"] == "development"
    config.secret_key_base = "synthetic-devise-consumer-secret-" * 4
    config.hosts = [ "www.example.com", "localhost", "127.0.0.1" ]
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = true
    config.session_store :cookie_store, key: "_support_consumer_session"
    config.active_storage.service = :local
    config.active_storage.variant_processor = :disabled
    config.action_mailer.delivery_method = :test
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
