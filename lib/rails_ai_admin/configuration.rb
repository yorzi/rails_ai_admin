# frozen_string_literal: true

module RailsAiAdmin
  # Declares host adapters as names so development reload resolves fresh classes.
  class Configuration
    INTERNAL_PATH = /\A\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]*\z/.freeze
    # Gems an opt-in feature needs in the host's own Gemfile. The gemspec does
    # not depend on them, so a conventional install pulls no AI code; boot
    # enforces the supported range instead (RAA-026).
    OPTIONAL_GEMS = {
      "rails_tool_views" => { constant: "::RailsToolViews::VERSION", requirement: [ "~> 1.0.2" ].freeze }.freeze,
      "ruby_llm" => { constant: "::RubyLLM::VERSION", requirement: [ ">= 2.2.0", "< 3" ].freeze }.freeze
    }.freeze

    # Nil when the loaded version of an optional gem is supported, otherwise a
    # message naming the feature, the range and what is loaded.
    def self.optional_gem_problem(name, feature, version: OPTIONAL_GEMS.fetch(name).fetch(:constant).safe_constantize)
      requirement = Gem::Requirement.new(*OPTIONAL_GEMS.fetch(name).fetch(:requirement))
      return if version && requirement.satisfied_by?(Gem::Version.new(version))
      "#{feature} needs #{name} #{requirement} in the host Gemfile (#{version ? "#{version} is loaded" : 'it is not loaded'})"
    end

    attr_accessor :context_adapter, :authorization_adapter, :resources, :title, :intent_ttl,
      :work_handlers, :outbox_auto_dispatch, :collection_auto_dispatch, :field_types, :authentication_path,
      # Opt-in rails_tool_views review Surfaces. The host loads rails_tool_views
      # and owns its global configuration; the admin never changes it.
      :surfaces,
      # Opt-in admin Chat. The host loads ruby_llm and names an adapter that
      # builds a RubyLLM::Context per admin Context; global RubyLLM settings
      # are never read for credentials or changed.
      :assistant, :assistant_adapter, :assistant_model, :assistant_provider, :assistant_protocol,
      # Messages one actor may send the assistant in any 24 hours; nil removes
      # the limit. Each message can cost several provider calls.
      :assistant_daily_message_limit,
      # :model shows the host model's validation messages for writable fields;
      # :generic shows "is invalid" for each, for hosts whose messages may
      # carry values an editor should not see (RAA-011).
      :validation_messages,
      # Optional short header badge such as "Staging" (RAA-024); none by default.
      :environment_label,
      # Active Job queue for collection, outbox and assistant jobs (RAA-020).
      # Workers with explicit queue lists must include it.
      :queue_name

    def initialize
      @authentication_path = nil
      @context_adapter = nil
      @authorization_adapter = "RailsAiAdmin::Authorization::Adapter"
      @resources = []
      @title = "Administration"
      @intent_ttl = 15.minutes
      @work_handlers = {}
      @outbox_auto_dispatch = false
      @collection_auto_dispatch = false
      @field_types = {}
      @surfaces = false
      @queue_name = "rails_ai_admin"
      @validation_messages = :model
      @assistant = false
      @assistant_adapter = nil
      @assistant_model = nil
      @assistant_provider = nil
      @assistant_protocol = nil
      @assistant_daily_message_limit = 100
    end

    # Validates and freezes the boot configuration without reading domain tables.
    def finalize!
      [ context_adapter, authorization_adapter ].compact.each do |name|
        raise ConfigurationError, "Adapters must be constant name strings" unless name.is_a?(String) && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      end
      unless resources.is_a?(Array) && resources.all? { |name| name.is_a?(String) }
        raise ConfigurationError, "resources must contain constant name strings"
      end
      raise ConfigurationError, "intent_ttl must be between 60 and 3600 seconds" unless (60..3600).cover?(intent_ttl)
      unless work_handlers.is_a?(Hash) && work_handlers.all? { |kind, name| kind.is_a?(String) && kind.match?(/\A[a-z][a-z0-9_.-]{0,99}\z/) && name.is_a?(String) && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) } && [ true, false ].include?(outbox_auto_dispatch)
        raise ConfigurationError, "work_handlers needs stable string keys/class names and outbox_auto_dispatch must be boolean"
      end
      raise ConfigurationError, "collection_auto_dispatch must be boolean" unless [ true, false ].include?(collection_auto_dispatch)
      raise ConfigurationError, "surfaces must be boolean" unless [ true, false ].include?(surfaces)
      unless environment_label.nil? || environment_label.is_a?(String) && environment_label.valid_encoding? && environment_label.length.between?(1, 40) && !environment_label.match?(/[[:cntrl:]]/)
        raise ConfigurationError, "environment_label must be nil or 1 to 40 characters of plain text"
      end
      environment_label&.freeze
      raise ConfigurationError, "validation_messages must be :model or :generic" unless %i[model generic].include?(validation_messages)
      unless (queue_name.is_a?(String) || queue_name.is_a?(Symbol)) && queue_name.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}\z/)
        raise ConfigurationError, "queue_name must be a short queue name"
      end
      self.queue_name = queue_name.to_s.freeze
      if surfaces && !defined?(::RailsToolViews::Engine)
        raise ConfigurationError, "surfaces requires the host to load rails_tool_views (add it to the Gemfile and run its installer)"
      end
      if surfaces && (problem = self.class.optional_gem_problem("rails_tool_views", "surfaces"))
        raise ConfigurationError, problem
      end
      if surfaces && (problem = surfaces_parent_controller_problem)
        raise ConfigurationError, problem
      end
      validate_assistant!
      unless authentication_path.nil? || authentication_path.is_a?(String) && authentication_path.valid_encoding? && authentication_path.ascii_only? && authentication_path.match?(INTERNAL_PATH)
        raise ConfigurationError, "authentication_path must be a fixed internal path without query or fragment"
      end
      authentication_path&.freeze
      Fields::Registry.new(field_types).validate!
      field_types.each { |key, name| key.freeze; name.freeze }
      field_types.freeze
      work_handlers.each { |kind, name| kind.freeze; name.freeze }
      work_handlers.freeze
      resources.each(&:freeze)
      resources.freeze
      title.freeze
      context_adapter&.freeze
      authorization_adapter.freeze
      [ assistant_adapter, assistant_model, assistant_provider, assistant_protocol ].each { |value| value&.freeze }
      freeze
    end

    # rails_tool_views' own controller inherits its parent_controller when the
    # host eager loads; a missing "::ApplicationController" (an API-only or
    # minimal host) would otherwise fail production boot with a bare NameError
    # (RAA-009, DEP-010). Returns nil when the parent resolves.
    def surfaces_parent_controller_problem
      return unless defined?(::RailsToolViews) && ::RailsToolViews.respond_to?(:configuration)
      name = ::RailsToolViews.configuration.parent_controller.to_s
      parent = name.safe_constantize
      return if parent.is_a?(Class) && parent <= ::ActionController::Base
      "surfaces needs rails_tool_views' parent_controller (#{name.inspect}) to name an ActionController::Base subclass. " \
        "Add that controller, or set config.parent_controller in your RailsToolViews.configure block."
    end

    private

    PROVIDER_NAME = /\A[a-z][a-z0-9_]{0,39}\z/

    def validate_assistant!
      raise ConfigurationError, "assistant must be boolean" unless [ true, false ].include?(assistant)
      return unless assistant
      unless defined?(::RubyLLM::Railtie)
        raise ConfigurationError, "assistant requires the host to load ruby_llm (add it to the Gemfile)"
      end
      if (problem = self.class.optional_gem_problem("ruby_llm", "assistant"))
        raise ConfigurationError, problem
      end
      unless assistant_adapter.is_a?(String) && assistant_adapter.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        raise ConfigurationError, "assistant_adapter must be a constant name string"
      end
      unless assistant_model.is_a?(String) && assistant_model.match?(/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,99}\z/)
        raise ConfigurationError, "assistant_model must name one model"
      end
      unless assistant_daily_message_limit.nil? || assistant_daily_message_limit.is_a?(Integer) && assistant_daily_message_limit.between?(1, 100_000)
        raise ConfigurationError, "assistant_daily_message_limit must be nil or a whole number from 1 to 100000"
      end
      [ assistant_provider, assistant_protocol ].each do |value|
        raise ConfigurationError, "assistant_provider and assistant_protocol must be short lowercase names" unless value.nil? || value.is_a?(String) && value.match?(PROVIDER_NAME)
      end
    end
  end
end
