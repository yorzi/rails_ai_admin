# frozen_string_literal: true

module RailsAiAdmin
  module Quality
    class Registry
      def initialize(names, resources)
        unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && name.match?(Configuration::CONSTANT_NAME) }
          raise ConfigurationError, "quality_rules must contain constant name strings"
        end
        @rules = {}
        names.each do |name|
          rule = name.safe_constantize
          raise ConfigurationError, "#{name} must inherit QualityRule" unless rule.is_a?(Class) && rule < QualityRule
          resource = resources.resources.find { |entry| entry.key == rule.resource }
          raise ConfigurationError, "#{name} needs a registered resource" unless resource
          rule.validate!(resource)
          key = [ resource.key, rule.key.to_s ]
          raise ConfigurationError, "Duplicate quality rule #{key.join('/')}" if @rules.key?(key)
          @rules[key] = rule
        end
        @rules.freeze
      end

      def for_access(access)
        @rules.values.select { |rule| rule.resource == access.resource.key && access.quality_rule_allowed?(rule) }
      end

      def fetch(resource, key)
        @rules.fetch([ resource.key, key.to_s ]) { raise AccessDenied }
      end
    end
  end
end
