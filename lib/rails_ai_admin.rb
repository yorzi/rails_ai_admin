# frozen_string_literal: true

require "rails"
require "rails/engine"
require "active_record"
require "action_controller/railtie"
require "active_job/railtie"
require "active_support/core_ext"
require_relative "rails_ai_admin/version"
require_relative "rails_ai_admin/error"
require_relative "rails_ai_admin/configuration"
require_relative "rails_ai_admin/context"
require_relative "rails_ai_admin/field"
require_relative "rails_ai_admin/input_schema"
require_relative "rails_ai_admin/resource"
require_relative "rails_ai_admin/registry"
require_relative "rails_ai_admin/authorization/adapter"
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

    # Rebuilds the registry from reloadable host constant names.
    def prepare!
      @registry = Registry.new(configuration.resources)
    end
  end
end

require_relative "rails_ai_admin/engine"
