# frozen_string_literal: true

require "json"

module RailsAiAdmin
  module Integrations
    # Admin review Surfaces on the host-owned rails_tool_views runtime.
    #
    # Required only when `config.surfaces` is enabled, so conventional boot never
    # loads rails_tool_views. The admin reads none of the host's global
    # rails_tool_views settings (resolver, parent controller, adapter,
    # auto_deliver) and changes none of them. Admin endpoints pass an explicit
    # `raa:` Scope and bind the current admin Context for the duration of one
    # call; policy and handler deny when no matching Context is bound, so another
    # route (such as the host's product engine mount) can never act on them.
    module ToolViews
      KEY = "raa_operation_review"
      VERSION = "1"
      PARTIAL = "rails_ai_admin/surfaces/operation_review"
      CONTEXT_KEY = :rails_ai_admin_surface_context
      UUID = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
      MAX_INPUT_BYTES = 16_384
      # Props hold only a server intent reference and its canonical wire input,
      # so the component digest never depends on reloadable host code.
      SCHEMA = {
        type: "object", additionalProperties: false, required: %w[intent input],
        properties: { intent: { type: "string", pattern: UUID, maxLength: 36 }, input: { type: "string", maxLength: MAX_INPUT_BYTES } }
      }.freeze
      CONFIRM_SCHEMA = { type: "object", additionalProperties: false, properties: {} }.freeze
      # Business outcomes are recorded on the Surface with their failure audit.
      TERMINAL = {
        "CONFLICT" => "The record changed or was busy. Start a new review from the record.",
        "APPROVAL_EXPIRED" => "This review expired. Start a new review from the record.",
        "APPROVAL_INVALIDATED" => "Access or the operation changed. Start a new review from the record.",
        "APPROVAL_REQUIRED" => "This operation needs a new review.",
        "VALIDATION_FAILED" => "The operation rejected this input. Start a new review from the record.",
        "IDEMPOTENCY_CONFLICT" => "This review no longer matches the recorded operation."
      }.freeze
      Review = ::Data.define(:run, :resource, :definition, :access, :record)

      class << self
        def available?
          defined?(::RailsToolViews::Registry) ? true : false
        end

        # Re-registers after a host `reset_registry!`. The contract is constant,
        # so an existing registration must be exactly this one.
        def ensure_registered!
          raise ConfigurationError, "rails_tool_views is not loaded" unless available?
          component = begin
            ::RailsToolViews.registry.fetch(KEY)
          rescue ::RailsToolViews::Error => error
            raise unless error.code == "UNKNOWN_COMPONENT"
            register
          end
          unless component.policy.equal?(POLICY) && component.actions.fetch("confirm").handler.equal?(CONFIRM)
            raise ConfigurationError, "#{KEY} is registered by other code"
          end
          component
        end

        def scope_for(context)
          raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
          ::RailsToolViews::Scope.new(actor: context.actor_ref, tenant: context.tenant_ref)
        end

        # Binds the current admin Context for one admin endpoint call.
        def with_context(context)
          raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
          state = ActiveSupport::IsolatedExecutionState
          previous = state[CONTEXT_KEY]
          state[CONTEXT_KEY] = context
          yield
        ensure
          state[CONTEXT_KEY] = previous if state
        end

        def current_context = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]

        # Presents (or replays) the review Surface for an unconsumed native intent.
        def present(context:, resource:, definition:, record:, intent_ref:, input:)
          ensure_registered!
          raise AccessDenied unless resource.surface_operation?(definition.key) && definition.custom? && definition.scope == :member
          raise AccessDenied unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
          run = OperationRun.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          unless run && run.id == intent_ref && run.resource_key == resource.key.to_s && run.operation == definition.key.to_s &&
              run.target_id == record.id.to_s && run.status == "proposed" && run.origin == "ui" && run.parent_run_id.nil?
            raise AccessDenied
          end
          raise AccessDenied, "APPROVAL_EXPIRED" unless run.expires_at && run.expires_at > Time.current
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.security_version == context.security_version
          wire = canonical_input(input)
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.input_digest && run.input_digest == InputSchema.digest(input_values(context, resource, definition, record, wire))
          reference = "raa:intent:#{run.id}"
          with_context(context) do
            ::RailsToolViews.present(KEY, props: { "intent" => run.id, "input" => wire }, scope: scope_for(context),
              context: reference, correlation: { adapter: "raa_native_review", call_id: run.id, context: reference })
          end
        end

        # Current authorized review for props, or nil. Never trusts the Surface.
        def review(context, props)
          return unless context.is_a?(Context) && props.is_a?(Hash) && props["intent"].is_a?(String)
          run = OperationRun.find_by(id: props["intent"], actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          return unless run && run.id == props["intent"] && run.parent_run_id.nil? && run.selection_id.nil?
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          return unless definition.custom? && definition.scope == :member && resource.surface_operation?(definition.key)
          access = Authorization::Access.new(context, resource)
          Review.new(run, resource, definition, access, access.find!(run.target_id))
        rescue AccessDenied, ConfigurationError, ActiveRecord::RecordNotFound
          nil
        end

        def authorize(access)
          context = current_context
          return false unless context.is_a?(Context) && access.actor == context.actor_ref && access.tenant == context.tenant_ref
          review = review(context, access.props)
          return false unless review
          case access.operation
          when :present then review.run.status == "proposed"
          # A completed review is a receipt: like native replay it needs the
          # independent receipt grant, not the (possibly lapsed) command grant.
          when :read then review.run.status != "succeeded" || receipt?(review)
          when :action then access.action == "confirm"
          else false
          end
        end

        def receipt?(review)
          review.access.authorize_receipt!(review.definition.key, review.record)
        rescue AccessDenied
          false
        end

        # The human's own submission of the Surface form is the confirmation.
        def confirm(request)
          context = current_context
          review = review(context, request.props) if context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless review
          run = review.run
          result = Operations::Runner.new.execute(context: context, intent_ref: run.id, input: JSON.parse(request.props.fetch("input")),
            human_confirmed: true, origin: :surface, binding: { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id })
          if result.success?
            message = result.replayed ? "This operation was already completed. No second change was made." : "Operation completed."
            ::RailsToolViews::Transition.new(state: { "outcome" => "succeeded", "message" => message }, agent: false)
          elsif TERMINAL.key?(result.code)
            ::RailsToolViews::Transition.new(state: { "outcome" => "rejected", "code" => result.code, "message" => TERMINAL.fetch(result.code) }, agent: false)
          elsif result.code == "NOT_FOUND"
            raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403)
          else
            # Nothing committed; the Surface revision is unchanged and retry is safe.
            raise ::RailsToolViews::Error.new("OPERATION_FAILED", status: 503, message: "The operation could not complete. Nothing was changed; try again.")
          end
        end

        # Typed display values. While proposed, only the actor's current input
        # grants; once committed, the recorded input through the operation's
        # declared contract (as receipt replay does), behind the receipt grant.
        def display_values(review, wire)
          values = JSON.parse(wire)
          fields = if review.run.status == "succeeded"
            review.definition.handler_class.input
          else
            begin
              review.definition.fields(review.access, review.record)
            rescue AccessDenied
              []
            end
          end
          fields.filter_map do |field|
            next unless values.key?(field.name.to_s)
            text = begin
              field.format(field.coerce(values[field.name.to_s], time_zone: review.access.context.time_zone), time_zone: review.access.context.time_zone)
            rescue ArgumentError
              "Unavailable"
            end
            [ field, text ]
          end
        rescue JSON::ParserError
          []
        end

        private

        def register
          ::RailsToolViews.register(KEY, description: "Admin operation review", version: VERSION, schema: SCHEMA, partial: PARTIAL,
            policy: POLICY, actions: { confirm: { schema: CONFIRM_SCHEMA, policy: POLICY, handler: CONFIRM } }, expose_to: [])
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "DUPLICATE_COMPONENT"
          ::RailsToolViews.registry.fetch(KEY)
        end

        def canonical_input(input)
          raise AccessDenied, "INVALID_QUERY" unless input.is_a?(Hash)
          stringified = input.to_h { |key, value| [ key.to_s, value ] }
          wire = JSON.generate(stringified.sort.to_h)
          raise AccessDenied, "INVALID_QUERY" if wire.bytesize > MAX_INPUT_BYTES
          wire
        end

        def input_values(context, resource, definition, record, wire)
          access = Authorization::Access.new(context, resource)
          result = InputSchema.new(definition.fields(access, record)).coerce(JSON.parse(wire), time_zone: context.time_zone)
          raise AccessDenied, "APPROVAL_INVALIDATED" unless result.valid?
          result.values
        end
      end

      POLICY = ->(access) { ToolViews.authorize(access) }
      CONFIRM = ->(request) { ToolViews.confirm(request) }
    end
  end
end
