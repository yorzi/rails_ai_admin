# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Operations
    # A signed, stateless reference for a native create/update/destroy form
    # (ADR 0025). Rendering the form writes nothing; the reference becomes an
    # OperationRun with the same identity on the first submit or explicit form
    # recovery, so a GET (or a Turbo hover prefetch) stays read-only (RAA-005).
    #
    # The payload binds the same values the GET used to write: owner, tenant,
    # security epoch, resource, operation fingerprint, target, record version
    # and expiry. It is signed, not encrypted; it carries only references the
    # holder already has. It is never authority on its own: every submit still
    # passes the Runner's current context, policy, field and version checks.
    module FormIntent
      PURPOSE = "rails_ai_admin/form_intent"
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      MAX_BYTES = 2048
      KEYS = %w[id actor_ref tenant_ref security_version resource_key operation operation_version target_id expected_version created_at expires_at].freeze
      OPERATIONS = %w[create update destroy].freeze

      class << self
        def uuid?(value) = value.is_a?(String) && value.match?(UUID)

        # Signature lifetime covers the one-hour recovery window even when the
        # configured intent TTL is shorter; the run itself keeps its own expiry.
        def generate(attributes, recovery_window:)
          payload = attributes.transform_keys(&:to_s).slice(*KEYS)
          raise ConfigurationError, "Form intent attributes are incomplete" unless (KEYS - payload.keys - %w[target_id expected_version]).empty?
          created = Time.iso8601(payload.fetch("created_at"))
          verifier.generate(payload, purpose: PURPOSE, expires_at: created + recovery_window)
        end

        # Returns the verified payload, or nil for anything else.
        def verify(reference)
          return unless reference.is_a?(String) && reference.bytesize <= MAX_BYTES && reference.valid_encoding? && reference.ascii_only?
          payload = verifier.verified(reference, purpose: PURPOSE)
          return unless payload.is_a?(Hash) && (payload.keys - KEYS).empty? && uuid?(payload["id"]) && OPERATIONS.include?(payload["operation"])
          payload
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, JSON::ParserError
          nil
        end

        # The OperationRun id a form reference will use, without creating it.
        def id_for(reference)
          uuid?(reference) ? reference : verify(reference)&.fetch("id")
        end

        # Row attributes for the first submit or recovery of this form.
        def run_attributes(payload)
          { id: payload.fetch("id"), actor_ref: payload.fetch("actor_ref"), tenant_ref: payload.fetch("tenant_ref"),
            security_version: payload.fetch("security_version"), resource_key: payload.fetch("resource_key"),
            operation: payload.fetch("operation"), operation_version: payload.fetch("operation_version"),
            target_id: payload["target_id"], expected_version: payload["expected_version"], origin: "ui",
            expires_at: Time.iso8601(payload.fetch("expires_at")), created_at: Time.iso8601(payload.fetch("created_at")) }
        end

        private

        def verifier
          raise ConfigurationError, "Form intents need a Rails application secret" unless defined?(::Rails) && ::Rails.application
          ::Rails.application.message_verifier(PURPOSE)
        end
      end
    end
  end
end
