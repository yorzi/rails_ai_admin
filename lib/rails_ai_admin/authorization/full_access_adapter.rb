# frozen_string_literal: true

module RailsAiAdmin
  module Authorization
    # Opt-in preset for trusted staff: everyone the context adapter admits may
    # use everything the registered resources declare. The resource files are
    # then the complete list of what the admin exposes: an undeclared column,
    # a hidden field, a readonly resource and a disabled action stay closed.
    #
    # It applies no tenant condition and no roles. Subclass it to narrow one
    # decision and keep the rest:
    #
    #   class AdminPolicyAdapter < RailsAiAdmin::Authorization::FullAccessAdapter
    #     def scope(context:, resource:, relation:)
    #       relation.where(account_id: context.tenant.id)
    #     end
    #   end
    #
    # The admin assistant stays closed here. Opening it sends record values to
    # a model provider, which is a separate decision from trusting a person.
    class FullAccessAdapter < Adapter
      def scope(context:, resource:, relation:)
        relation.all
      end

      # Access still requires the resource to enable the action.
      def allowed?(context:, action:, resource:, record: nil)
        true
      end

      # Access narrows these to what each field declares: writable, searchable,
      # sortable and filterable flags, hidden fields and write-only passwords.
      def fields(context:, resource:, action:, record: nil)
        resource.fields.map(&:name)
      end

      def operation_fields(context:, resource:, operation:, record: nil)
        RailsAiAdmin.operation_registry.fetch(resource, operation).handler_class.input.map(&:name)
      end

      def deliver_work?(context:, resource:, operation:, work_kind:, record:)
        true
      end

      def read_operation_receipt?(context:, resource:, operation:, record:)
        true
      end

      def cancel_operation?(context:, resource:, operation:)
        true
      end

      def named_scopes(context:, resource:)
        resource.scopes.map(&:name)
      end

      def select_records?(context:, resource:)
        true
      end

      def export_records?(context:, resource:)
        true
      end

      def import_records?(context:, resource:)
        true
      end

      def view_audit_log?(context:, resource:)
        true
      end

      def view_history?(context:, resource:, record:)
        true
      end
    end
  end
end
