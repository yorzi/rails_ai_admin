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
require_relative "rails_ai_admin/presentation/status"
require_relative "rails_ai_admin/presentation/outcomes"
require_relative "rails_ai_admin/configuration"
require_relative "rails_ai_admin/context"
require_relative "rails_ai_admin/record_version"
require_relative "rails_ai_admin/field"
require_relative "rails_ai_admin/fields/hook_signatures"
require_relative "rails_ai_admin/fields/type"
require_relative "rails_ai_admin/fields/computation"
require_relative "rails_ai_admin/fields/dependency_graph"
require_relative "rails_ai_admin/fields/projection"
require_relative "rails_ai_admin/fields/file_value"
require_relative "rails_ai_admin/fields/registry"
require_relative "rails_ai_admin/fields/scalar_schema"
require_relative "rails_ai_admin/input_schema"
require_relative "rails_ai_admin/forms/plan"
require_relative "rails_ai_admin/operation"
require_relative "rails_ai_admin/work"
require_relative "rails_ai_admin/navigation/settings"
require_relative "rails_ai_admin/queries/named_scope"
require_relative "rails_ai_admin/presentation/index_settings"
require_relative "rails_ai_admin/presentation/association_panel"
require_relative "rails_ai_admin/presentation/history"
require_relative "rails_ai_admin/presentation/audit_log"
require_relative "rails_ai_admin/resource"
require_relative "rails_ai_admin/resource_identity"
require_relative "rails_ai_admin/registry"
require_relative "rails_ai_admin/quality_rule"
require_relative "rails_ai_admin/quality/registry"
require_relative "rails_ai_admin/quality/runner"
require_relative "rails_ai_admin/quality/checks"
require_relative "rails_ai_admin/quality/merge_operation"
require_relative "rails_ai_admin/quality/merge_review"
require_relative "rails_ai_admin/operations/default_handlers"
require_relative "rails_ai_admin/operations/registry"
require_relative "rails_ai_admin/outbox/registry"
require_relative "rails_ai_admin/request_log_filter"
require_relative "rails_ai_admin/authorization/adapter"
require_relative "rails_ai_admin/authorization/pundit_adapter"
require_relative "rails_ai_admin/authorization/full_access_adapter"
require_relative "rails_ai_admin/authorization/access"
require_relative "rails_ai_admin/fields/association"
require_relative "rails_ai_admin/navigation/list_state"
require_relative "rails_ai_admin/navigation/menu"
require_relative "rails_ai_admin/navigation/saved_views"

# Provides an isolated admin engine. The host supplies all authority.
module RailsAiAdmin
  Snapshot = Data.define(:registry, :operation_registry, :work_registry, :field_registry, :quality_registry)

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
      @snapshot&.registry || (@registry ||= Registry.new([]))
    end

    def field_registry
      prepared = @snapshot&.field_registry
      return prepared if prepared&.matches?(configuration.field_types)
      Fields::Registry.new(configuration.field_types)
    end

    def operation_registry
      @snapshot&.operation_registry || (@operation_registry ||= Operations::Registry.new([]))
    end

    def quality_registry
      @snapshot&.quality_registry || (@quality_registry ||= Quality::Registry.new([], registry))
    end

    def work_registry
      @snapshot&.work_registry || (@work_registry ||= Outbox::Registry.new({}))
    end

    # Rebuilds the registry from reloadable host constant names and publishes
    # the tuple as one atomic reference swap.
    def prepare!
      fields = Fields::Registry.new(configuration.field_types).validate!
      resources = Registry.new(configuration.resources)
      operations = Operations::Registry.new(resources.resources)
      work = Outbox::Registry.new(configuration.work_handlers)
      quality = Quality::Registry.new(configuration.quality_rules, resources)
      @snapshot = Snapshot.new(registry: resources, operation_registry: operations, work_registry: work, field_registry: fields, quality_registry: quality)
    end
  end
end

require_relative "rails_ai_admin/queries/list"
require_relative "rails_ai_admin/presentation/csv_export"
require_relative "rails_ai_admin/presentation/csv_import"
require_relative "rails_ai_admin/presentation/import_review"
require_relative "rails_ai_admin/presentation/dashboard"
require_relative "rails_ai_admin/operations/result"
require_relative "rails_ai_admin/outbox/writer"
require_relative "rails_ai_admin/operations/execution_context"
require_relative "rails_ai_admin/operations/runner_fingerprint"
require_relative "rails_ai_admin/operations/form_intent"
require_relative "rails_ai_admin/operations/runner"
require_relative "rails_ai_admin/operations/restore"
require_relative "rails_ai_admin/operations/bulk_change"
require_relative "rails_ai_admin/selections/builder"
require_relative "rails_ai_admin/collections/result"
require_relative "rails_ai_admin/collections/contract"
require_relative "rails_ai_admin/collections/runner"
require_relative "rails_ai_admin/collections/claim"
require_relative "rails_ai_admin/collections/dispatcher"
require_relative "rails_ai_admin/collections/queries"
require_relative "rails_ai_admin/tasks/coordinator"
require_relative "rails_ai_admin/tasks/review"
require_relative "rails_ai_admin/outbox/request_digest"
require_relative "rails_ai_admin/outbox/delivery_context"
require_relative "rails_ai_admin/outbox/dispatcher"
require_relative "rails_ai_admin/engine"
