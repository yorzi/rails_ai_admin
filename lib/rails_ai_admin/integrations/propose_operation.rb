# frozen_string_literal: true

require "active_support/core_ext/digest/uuid"
require "ruby_llm"
require "rails_ai_admin/integrations/tool_views"

module RailsAiAdmin
  module Integrations
    # A RubyLLM tool that lets an assistant propose an opted-in member operation.
    #
    # The model chooses a resource, record, operation and input; all of it is
    # untrusted. The server re-runs the normal preflight under the current admin
    # Context (policy scope, action and input grants, typed coercion) and then
    # presents the review Surface. The tool cannot confirm or execute anything:
    # only the human's own Surface submission does, through the shared Runner.
    #
    # Each provider tool call maps to one deterministic intent and one Surface,
    # so a replayed call (for example after a crash before its result was saved)
    # never creates a second approval request.
    class ProposeOperation < ::RubyLLM::Tool
      NAMESPACE = "9b2f2f41-2a4e-4d7b-9bde-8f3f6a1d0c55"
      CONVERSATION = /\Araa:conversation:[A-Za-z0-9_-]{1,100}\z/
      RECORD_REF = /\A[A-Za-z0-9_-]{1,64}\z/

      def self.tool_name = "raa_propose_operation"

      description "Propose an admin operation on one record. Nothing changes until the signed-in user reviews and confirms it in the interactive review this presents. Never tell the user the operation is done."

      attr_reader :catalog

      # context: the authenticated admin Context; conversation: a server-owned
      # "raa:conversation:<id>" reference. Neither may come from model output.
      def initialize(context:, conversation:)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        unless conversation.is_a?(String) && conversation.match?(CONVERSATION)
          raise ConfigurationError, "conversation must be a raa:conversation reference"
        end
        raise ConfigurationError, "Assistant proposals require config.surfaces" unless RailsAiAdmin.configuration.surfaces
        @context, @conversation = context, conversation.dup.freeze
        @catalog = build_catalog.freeze
        super()
      end

      def description
        operations = @catalog.map do |entry|
          fields = entry[:definition].handler_class.input.map do |field|
            values = field.choice_values.any? ? " (#{field.choice_values.join('|')})" : ""
            "#{field.name}: #{field.scalar_type}#{values}#{field.options[:required] ? ', required' : ''}"
          end
          "#{entry[:resource].key}.#{entry[:definition].key} — #{entry[:definition].description}; input #{fields.join('; ')}"
        end
        "#{self.class.description} Available: #{operations.join(' | ')}"
      end

      def parameters_schema
        {
          "type" => "object", "additionalProperties" => false, "required" => %w[resource record operation input],
          "properties" => {
            "resource" => { "type" => "string", "enum" => @catalog.map { |entry| entry[:resource].key.to_s }.uniq },
            "record" => { "type" => "string", "maxLength" => 64, "description" => "The record id shown in the admin" },
            "operation" => { "type" => "string", "enum" => @catalog.map { |entry| entry[:definition].key.to_s }.uniq },
            "input" => { "type" => "object", "description" => "Operation input fields by name" }
          }
        }
      end

      def execute(resource:, record:, operation:, input:, tool_call: nil)
        raise AccessDenied, "INVALID_TOOL_CALL" unless tool_call.is_a?(::RubyLLM::ToolCall) && tool_call.name == name && tool_call.id.is_a?(String) && tool_call.id.bytesize.between?(1, 150)
        entry = @catalog.find { |item| item[:resource].key.to_s == resource.to_s && item[:definition].key.to_s == operation.to_s }
        raise AccessDenied unless entry && record.is_a?(String) && record.match?(RECORD_REF) && input.is_a?(Hash)
        resource, definition = entry[:resource], entry[:definition]
        intent_id = Digest::UUID.uuid_v5(NAMESPACE, [ @context.actor_ref, @context.tenant_ref, @conversation, tool_call.id ].join("\n"))
        # A replay of an already confirmed call reports it before re-checking the
        # command grant, which a completed change may legitimately withdraw.
        done = OperationRun.find_by(id: intent_id, actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref, status: "succeeded")
        if done && done.origin == "assistant" && done.resource_key == resource.key.to_s && done.operation == definition.key.to_s
          return { status: "reviewed", message: "The user already confirmed this proposal. Do not propose it again." }
        end
        access = Authorization::Access.new(@context, resource)
        target = access.find!(record, action: definition.key)
        values = proposal_values(resource, definition, target, input, intent_id)
        return values if values.key?(:status)
        surface = ToolViews.present(context: @context, resource: resource, definition: definition, record: target,
          intent_ref: intent_id, input: ToolViews.wire_input(values),
          assistant_call: { call_id: tool_call.id, conversation: @conversation })
        { status: "presented", surface_id: surface.id,
          message: "An interactive review was shown to the user. Nothing has changed; the user must confirm it." }
      rescue AccessDenied => error
        rejection(error.code)
      rescue ::RailsToolViews::Error => error
        rejection(error.code == "IDEMPOTENCY_CONFLICT" ? "IDEMPOTENCY_CONFLICT" : "NOT_FOUND")
      end

      private

      # Opted-in operations on resources the actor may currently list.
      def build_catalog
        RailsAiAdmin.registry.resources.flat_map do |resource|
          access = Authorization::Access.new(@context, resource)
          begin
            access.authorize!(:index)
          rescue AccessDenied
            next []
          end
          resource.assistant_operations.filter_map do |key|
            definition = RailsAiAdmin.operation_registry.fetch(resource, key)
            { resource: resource, definition: definition } if definition.custom? && definition.scope == :member
          end
        end
      end

      # Typed values of a new or replayed intent for this exact tool call.
      def proposal_values(resource, definition, target, input, intent_id)
        existing = OperationRun.find_by(id: intent_id, actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
        unless existing
          begin
            proposal = Operations::Runner.new.preflight(context: @context, resource: resource, operation: definition.key,
              target_id: target.id, expected_version: target.lock_version, input: input, origin: :assistant, intent_id: intent_id)
          rescue ActiveRecord::RecordNotUnique
            existing = OperationRun.find_by(id: intent_id, actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
          end
          if proposal.is_a?(Operations::Result)
            declared = definition.handler_class.input.map { |field| field.name.to_s }
            return { status: "rejected", code: proposal.code, fields: (proposal.errors.keys & declared).sort }
          end
          return proposal.values if proposal
        end
        raise AccessDenied unless existing && existing.origin == "assistant" && existing.resource_key == resource.key.to_s &&
          existing.operation == definition.key.to_s && existing.target_id == target.id.to_s
        raise AccessDenied, "IDEMPOTENCY_CONFLICT" unless existing.status == "proposed"
        result = InputSchema.new(definition.fields(Authorization::Access.new(@context, resource), target)).coerce(input, time_zone: @context.time_zone)
        raise AccessDenied, "IDEMPOTENCY_CONFLICT" unless result.valid? && InputSchema.digest(result.values) == existing.input_digest
        result.values
      end

      MESSAGES = {
        "NOT_FOUND" => "That record or operation is not available to this user.",
        "VALIDATION_FAILED" => "The proposed input is invalid for this operation.",
        "CONFLICT" => "The record changed; look it up again before proposing.",
        "IDEMPOTENCY_CONFLICT" => "This tool call was already used for a different proposal.",
        "INVALID_TOOL_CALL" => "This proposal must come from a tool call."
      }.freeze

      def rejection(code)
        code = MESSAGES.key?(code) ? code : "NOT_FOUND"
        { status: "rejected", code: code, message: MESSAGES.fetch(code) }
      end
    end
  end
end
