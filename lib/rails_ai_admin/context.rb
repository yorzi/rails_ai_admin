# frozen_string_literal: true

module RailsAiAdmin
  # Holds authority resolved by the host for one request or job attempt.
  # No process-global Current state or provider credentials are retained.
  class Context
    attr_reader :actor, :tenant, :actor_ref, :tenant_ref, :security_version, :time_zone

    def initialize(actor:, tenant:, security_version:, time_zone: "UTC")
      @actor, @tenant = actor, tenant
      @actor_ref = reference("actor", actor)
      @tenant_ref = reference("tenant", tenant)
      @security_version = security_version.to_s.dup.freeze
      raise AccessDenied, "UNAUTHENTICATED" if @security_version.empty? || @security_version.bytesize > 150
      raise ConfigurationError, "Unknown time zone" unless ActiveSupport::TimeZone[time_zone]
      @time_zone = time_zone.dup.freeze
      freeze
    end

    private

    def reference(kind, object)
      raise AccessDenied, "UNAUTHENTICATED" unless object && object.class.name.present? && object.respond_to?(:id) && object.id.present?
      ref = "raa:#{kind}:#{object.class.name}:#{object.id}"
      raise AccessDenied, "UNAUTHENTICATED" if ref.bytesize > 150 || ref.match?(/[\x00-\x1f\x7f]/)
      ref.freeze
    end
  end
end
