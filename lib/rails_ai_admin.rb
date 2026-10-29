# frozen_string_literal: true

require "rails"
require "rails/engine"
require "active_record"
require "action_controller/railtie"
require "active_job/railtie"
require "turbo-rails"
require "active_support/core_ext"
require_relative "rails_ai_admin/version"
require_relative "rails_ai_admin/error"
require_relative "rails_ai_admin/configuration"
require_relative "rails_ai_admin/context"
require_relative "rails_ai_admin/field"
require_relative "rails_ai_admin/input_schema"
require_relative "rails_ai_admin/operation"
require_relative "rails_ai_admin/work"
require_relative "rails_ai_admin/resource"
require_relative "rails_ai_admin/resource_identity"
require_relative "rails_ai_admin/registry"
require_relative "rails_ai_admin/operations/default_handlers"
require_relative "rails_ai_admin/operations/registry"
require_relative "rails_ai_admin/outbox/registry"
require_relative "rails_ai_admin/request_log_filter"
require_relative "rails_ai_admin/authorization/adapter"
require_relative "rails_ai_admin/authorization/pundit_adapter"
require_relative "rails_ai_admin/authorization/access"

# Provides an isolated admin engine. The host supplies all authority.
module RailsAiAdmin
  class << self
    # Returns the process configuration, frozen after Rails initialization.
    def configuration
      @configuration ||= Configuration.new
    end

    # Yields configuration during host initialization.
    def configure
      yield configuration
    end

    # Returns the current registry, rebuilt on Rails reload.
    def registry
      @registry ||= Registry.new([])
    end

    def operation_registry
      @operation_registry ||= Operations::Registry.new([])
    end

    def work_registry
      @work_registry ||= Outbox::Registry.new({})
    end

    # Rebuilds the registry from reloadable host constant names.
    def prepare!
      resources = Registry.new(configuration.resources)
      operations = Operations::Registry.new(resources.resources)
      work = Outbox::Registry.new(configuration.work_handlers)
      @registry, @operation_registry, @work_registry = resources, operations, work
    end
  end
end

require_relative "rails_ai_admin/queries/list"
require_relative "rails_ai_admin/operations/result"
require_relative "rails_ai_admin/outbox/writer"
require_relative "rails_ai_admin/operations/execution_context"
require_relative "rails_ai_admin/operations/runner_fingerprint"
require_relative "rails_ai_admin/operations/runner"
require_relative "rails_ai_admin/selections/builder"
require_relative "rails_ai_admin/outbox/request_digest"
require_relative "rails_ai_admin/outbox/delivery_context"
require_relative "rails_ai_admin/outbox/dispatcher"
require_relative "rails_ai_admin/engine"
