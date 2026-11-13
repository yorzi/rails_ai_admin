# frozen_string_literal: true

module RailsAiAdmin
  # Maps stable slugs to explicit reloadable resources, never arbitrary constants.
  class Registry
    RESERVED = %w[assistant audit dashboards exports imports jobs selections settings doctor assets search mcp].freeze

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
      # Targets resolve at boot without loading models; reflection agreement
      # is checked on first use and by doctor.
      @entries.each_value do |resource|
        resource.fields.each do |field|
          next unless Field::REFERENCE_TYPES.include?(field.scalar_type) && !@entries.key?(field.options[:resource].to_s)
          raise ConfigurationError, "#{resource.name} #{field.scalar_type} #{field.name} names unregistered resource #{field.options[:resource]}"
        end
        resource.has_many_declarations.each do |panel|
          child = @entries[panel.resource.to_s]
          via = child&.fields&.find { |field| field.name == panel.via(resource) }
          unless via&.scalar_type == :belongs_to
            raise ConfigurationError, "#{resource.name} has_many #{panel.name} needs registered resource #{panel.resource} with belongs_to #{panel.via(resource)}"
          end
        end
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
