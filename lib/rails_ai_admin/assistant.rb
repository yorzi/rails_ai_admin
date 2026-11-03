# frozen_string_literal: true

module RailsAiAdmin
  # Opt-in admin Chat on RubyLLM (ADR 0022). Loaded only when
  # `config.assistant` is enabled, so conventional hosts never load RubyLLM.
  module Assistant
    class << self
      def enabled? = RailsAiAdmin.configuration.assistant == true

      # True when at least one registered resource is exposed to this actor.
      def available?(context)
        context.is_a?(Context) && RailsAiAdmin.registry.resources.any? do |resource|
          Authorization::Access.new(context, resource).authorize_assistant!
        rescue AccessDenied
          false
        end
      end

      # The host's per-request provider configuration. nil means the assistant
      # is unavailable for this actor, which is a normal, recoverable state.
      def llm_context(context)
        adapter = RailsAiAdmin.configuration.assistant_adapter.constantize.new
        raise ConfigurationError, "assistant_adapter must define llm_context(context:)" unless adapter.respond_to?(:llm_context)
        value = adapter.llm_context(context: context)
        return nil if value.nil?
        raise ConfigurationError, "llm_context must return a RubyLLM::Context" unless value.is_a?(::RubyLLM::Context)
        value
      end

      def create_chat!(context)
        Chat.create!(ref: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          security_version: context.security_version, model: RailsAiAdmin.configuration.assistant_model,
          provider: RailsAiAdmin.configuration.assistant_provider)
      end

      def tool_views
        require "rails_ai_admin/integrations/tool_views"
        Integrations::ToolViews
      end
    end
  end
end

require "ruby_llm"
require_relative "assistant/records"
require_relative "assistant/tools"
require_relative "assistant/runtime"
require_relative "assistant/coordinator"
require_relative "assistant/continuation"
require_relative "assistant/transcript"
