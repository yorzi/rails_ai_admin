# frozen_string_literal: true

module RailsAiAdmin
  # Trusted host detector. Findings identify candidate records; the runner
  # resolves them again before presenting any evidence.
  class QualityRule
    extend Fields::HookSignatures

    class << self
      def key(value = nil)
        @key = value unless value.nil?
        @key
      end

      def resource(value = nil)
        @resource = value unless value.nil?
        @resource
      end

      def severity(value = nil)
        @severity = value unless value.nil?
        @severity.nil? ? :warning : @severity
      end

      def description(value = nil)
        @description = value unless value.nil?
        @description
      end

      def max_findings(value = nil)
        @max_findings = value unless value.nil?
        @max_findings.nil? ? 50 : @max_findings
      end

      def max_duration(value = nil)
        @max_duration = value unless value.nil?
        @max_duration.nil? ? 5 : @max_duration
      end

      def remediation_change(value = nil)
        @remediation_change = value unless value.nil?
        @remediation_change
      end

      def remediation_operation(value = nil)
        @remediation_operation = value unless value.nil?
        @remediation_operation
      end

      def validate!(registered)
        unless key.is_a?(Symbol) && Field::NAME.match?(key.to_s) && key.to_s.size <= 64
          raise ConfigurationError, "#{name} needs a stable rule key"
        end
        unless description.is_a?(String) && description.valid_encoding? && description.length.between?(1, 300) && !description.match?(Field::TEXT_CONTROLS)
          raise ConfigurationError, "#{name} needs a plain text description of up to 300 characters"
        end
        raise ConfigurationError, "#{name} has invalid severity" unless %i[info warning critical].include?(severity)
        unless max_findings.is_a?(Integer) && max_findings.between?(1, 100) && max_duration.is_a?(Integer) && max_duration.between?(1, 30)
          raise ConfigurationError, "#{name} needs max_findings (1..100) and max_duration (1..30 seconds)"
        end
        unless accepts?(instance_method(:initialize), 0, []) && public_method_defined?(:detect) && accepts?(instance_method(:detect), 2, [])
          raise ConfigurationError, "#{name} needs a no-argument constructor and detect(context, relation)"
        end
        if remediation_change && (remediation_change != :update || !registered.action_enabled?(:update) || remediation_operation)
          raise ConfigurationError, "#{name} must choose a single enabled remediation"
        end
        if remediation_operation && !(registered.operation_scopes[remediation_operation] == :member && registered.action_enabled?(remediation_operation))
          raise ConfigurationError, "#{name} needs an enabled member operation"
        end
      end
    end
  end
end
