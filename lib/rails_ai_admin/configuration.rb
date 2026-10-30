# frozen_string_literal: true

module RailsAiAdmin
  # Declares host adapters as names so development reload resolves fresh classes.
  class Configuration
    attr_accessor :context_adapter, :authorization_adapter, :resources, :title, :intent_ttl,
      :work_handlers, :outbox_auto_dispatch, :collection_auto_dispatch, :field_types, :authentication_path

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
      unless authentication_path.nil? || authentication_path.is_a?(String) && authentication_path.match?(/\A\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]*\z/)
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
      freeze
    end
  end
end
