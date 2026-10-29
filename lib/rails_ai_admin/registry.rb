# frozen_string_literal: true

module RailsAiAdmin
  # Maps stable slugs to explicit reloadable resources, never arbitrary constants.
  class Registry
    RESERVED = %w[assistant audit dashboards exports imports jobs selections settings doctor assets].freeze

    def initialize(names)
      @entries = {}
      names.each do |name|
        resource = name.constantize
        raise ConfigurationError, "#{name} must inherit Resource" unless resource < Resource
        key = resource.key.to_s
        if !key.match?(/\A[a-z][a-z0-9_]*\z/) || RESERVED.include?(key)
          raise ConfigurationError, "Invalid or reserved resource key #{key}"
        end
        raise ConfigurationError, "Duplicate resource key #{key}" if @entries.key?(key)
        @entries[key] = resource.validate!
      end
      @entries.freeze
      freeze
    end

    def fetch(key)
      @entries.fetch(key.to_s) { raise AccessDenied }
    end

    def resources = @entries.values
  end
end
