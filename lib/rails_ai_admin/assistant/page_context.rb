# frozen_string_literal: true

require "active_support/security_utils"

module RailsAiAdmin
  module Assistant
    # Server-issued, encrypted and signed snapshot of the current admin page
    # (record, fixed selection, or canonical list view). Distinct from the
    # host's AdminContext adapter and RailsAiAdmin::Context.
    #
    # A token is a reference, never authorization: resolving it re-checks
    # actor, tenant, security_version, assistant?, and live resource/record/
    # filter grants, failing closed on any tamper, expiry, or revocation.
    module PageContext
      PURPOSE = "rails_ai_admin/page_context"
      VERSION = 1
      MAX_TOKEN = 8_192
      TTL = 1.hour
      MAX_IDS_IN_SUMMARY = 20
      # Raised when an authentic context or its fixed selection has lapsed.
      EXPIRED = "CONTEXT_EXPIRED"

      Issued = ::Data.define(:token, :label, :resource_key, :kind)
      Snapshot = ::Data.define(:kind, :resource, :record_id, :selection_ref, :list_state, :label, :summary)

      module_function

      def issue(context:, resource:, record: nil, selection: nil, list_state: nil)
        return unless context.is_a?(Context) && resource.is_a?(Class) && resource < Resource
        access = Authorization::Access.new(context, resource)
        access.authorize_assistant!
        payload, label, kind = build_payload(access, resource, record: record, selection: selection, list_state: list_state)
        return unless payload
        token = encryptor.encrypt_and_sign(payload.merge(
          "v" => VERSION,
          "a" => context.actor_ref,
          "t" => context.tenant_ref,
          "sv" => context.security_version,
          "r" => resource.key.to_s
        ), purpose: PURPOSE, expires_at: Time.current + TTL)
        Issued.new(token: token, label: label, resource_key: resource.key.to_s, kind: kind)
      rescue AccessDenied, ConfigurationError
        nil
      end

      def resolve!(context:, token:)
        raise AccessDenied unless context.is_a?(Context) && token.is_a?(String) &&
          token.valid_encoding? && token.bytesize.between?(1, MAX_TOKEN)
        payload = encryptor.decrypt_and_verify(token, purpose: PURPOSE)
        # An authentic token past its lifetime decrypts to nil. That is the
        # page staying open too long, not tampering, so callers can keep the
        # person's text and ask them to drop or refresh the context.
        raise AccessDenied, EXPIRED if payload.nil?
        unless payload.is_a?(Hash) && payload["v"] == VERSION &&
            same_text?(payload["a"], context.actor_ref) &&
            same_text?(payload["t"], context.tenant_ref) &&
            same_text?(payload["sv"], context.security_version) &&
            payload["r"].is_a?(String) && payload["k"].is_a?(String)
          raise AccessDenied
        end
        resource = RailsAiAdmin.registry.fetch(payload["r"])
        access = Authorization::Access.new(context, resource)
        access.authorize_assistant!
        case payload["k"]
        when "record" then resolve_record!(access, resource, payload["id"])
        when "selection" then resolve_selection!(context, resource, payload["s"])
        when "list" then resolve_list!(access, resource, payload["l"])
        else raise AccessDenied
        end
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature,
          JSON::ParserError, ArgumentError, TypeError, KeyError, ConfigurationError
        raise AccessDenied
      end

      def resolve(context:, token:)
        resolve!(context: context, token: token)
      rescue AccessDenied
        nil
      end

      def build_payload(access, resource, record:, selection:, list_state:)
        if selection
          return unless selection.is_a?(Selections::Builder::Snapshot) &&
            selection.resource_key == resource.key.to_s && selection.targets.any?
          label = "#{resource.label} · #{selection.targets.size} selected"
          [ { "k" => "selection", "s" => selection.selection_ref }, label, :selection ]
        elsif record
          return unless record.is_a?(resource.model_class) && record.persisted? &&
            access.canonical_id?(record.id.to_s)
          record_title = access.record_label(record).truncate(60)
          label = "#{resource.label.singularize}: #{record_title}"
          [ { "k" => "record", "id" => record.id.to_s }, label, :record ]
        else
          access.authorize!(:index)
          state = Navigation::ListState.new(access, list_state).state.except("page")
          [ { "k" => "list", "l" => state }, list_chip_label(resource, state, access), :list ]
        end
      end

      def resolve_record!(access, resource, id)
        raise AccessDenied unless id.is_a?(String) && id.present? && access.canonical_id?(id)
        record = access.find!(id)
        title = access.record_label(record).truncate(120)
        summary = "Context: I am looking at #{resource.label.singularize} #{record.id} (\"#{title}\") in the #{resource.key} resource."
        Snapshot.new(kind: :record, resource: resource, record_id: record.id.to_s, selection_ref: nil,
          list_state: nil, label: "#{resource.label.singularize}: #{title.truncate(60)}", summary: summary)
      end

      def resolve_selection!(context, resource, selection_ref)
        raise AccessDenied unless selection_ref.is_a?(String) && selection_ref.present?
        summary_obj = begin
          Selections::Builder.new.revalidate(context: context, selection_ref: selection_ref)
        rescue AccessDenied => error
          raise AccessDenied, (error.code == "SELECTION_EXPIRED" ? EXPIRED : error.code)
        end
        raise AccessDenied unless summary_obj.resource_key == resource.key.to_s && summary_obj.targets.any?
        ids = summary_obj.targets.map(&:id)
        shown = ids.first(MAX_IDS_IN_SUMMARY)
        extra = ids.size > shown.size ? " and #{ids.size - shown.size} more" : ""
        summary = "Context: I am looking at a fixed selection of #{ids.size} #{resource.label} in the #{resource.key} resource " \
          "(IDs: #{shown.join(', ')}#{extra})."
        Snapshot.new(kind: :selection, resource: resource, record_id: nil, selection_ref: summary_obj.selection_ref,
          list_state: nil, label: "#{resource.label} · #{ids.size} selected", summary: summary)
      end

      def resolve_list!(access, resource, raw_state)
        access.authorize!(:index)
        state = Navigation::ListState.new(access, raw_state.is_a?(Hash) ? raw_state : {}).state.except("page")
        details = []
        details << "searching for \"#{state['q'].first(100)}\"" if state["q"].present?
        if state["scope"].present? && state["scope"] != Queries::NamedScope::NONE
          scope = access.named_scopes.find { |definition| definition.name.to_s == state["scope"] }
          details << "on the #{scope.label} tab (scope #{scope.name})" if scope
        end
        if state["filter"].is_a?(Hash) && state["filter"].any?
          parts = state["filter"].flat_map do |field, operators|
            operators.map { |operator, value| "#{field} #{operator} #{Array(value).join(',')}" }
          end
          details << "filtered by #{parts.first(8).join(', ').truncate(180)}" if parts.any?
        end
        if state["sort"].present?
          details << "sorted by #{state['sort']} #{state['direction'] || 'asc'}"
        end
        summary = "Context: I am looking at the #{resource.label} list (the #{resource.key} resource)#{details.any? ? ", #{details.join(', ')}" : ''}."
        Snapshot.new(kind: :list, resource: resource, record_id: nil, selection_ref: nil,
          list_state: state, label: list_chip_label(resource, state, access), summary: summary)
      end

      def list_chip_label(resource, state, access)
        parts = [ resource.label ]
        if state["scope"].present? && state["scope"] != Queries::NamedScope::NONE
          scope = access.named_scopes.find { |definition| definition.name.to_s == state["scope"] }
          parts << scope.label if scope
        end
        filter_count = state["filter"].is_a?(Hash) ? state["filter"].values.sum(&:size) : 0
        if state["q"].present?
          parts << "\"#{state['q'].truncate(24)}\""
        elsif filter_count.positive?
          parts << "#{filter_count} #{filter_count == 1 ? 'filter' : 'filters'}"
        end
        parts.join(" · ")
      end

      def same_text?(actual, expected)
        actual.is_a?(String) && expected.is_a?(String) &&
          actual.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      end

      def encryptor
        secret = ::Rails.application.key_generator.generate_key(PURPOSE, ActiveSupport::MessageEncryptor.key_len)
        ActiveSupport::MessageEncryptor.new(secret, serializer: JSON)
      end
    end
  end
end
