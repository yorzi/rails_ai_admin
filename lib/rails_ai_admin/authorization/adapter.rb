# frozen_string_literal: true

module RailsAiAdmin
  module Authorization
    # Default-deny policy interface. Hosts explicitly implement every permission.
    class Adapter
      def scope(context:, resource:, relation:)
        relation.none
      end

      def allowed?(context:, action:, resource:, record: nil)
        false
      end

      # action is :read, :write, :search, :sort or :filter; no implicit grants.
      # Filtering reveals values through membership, so it is never implied by read.
      def fields(context:, resource:, action:, record: nil)
        []
      end

      # Optional per-view narrowing, never a replacement for read/write grants.
      # nil adds no restriction; [] hides every field in that view.
      def presentation_fields(context:, resource:, view:, record: nil)
        nil
      end

      # Custom operation inputs are independent of ordinary attribute write grants.
      def operation_fields(context:, resource:, operation:, record: nil)
        []
      end

      # Delivery authorizes a committed fact, not re-execution of its command.
      def deliver_work?(context:, resource:, operation:, work_kind:, record:)
        false
      end

      def read_operation_receipt?(context:, resource:, operation:, record:)
        false
      end

      def cancel_operation?(context:, resource:, operation:)
        false
      end

      # Named list scopes (declared tabs) this actor may use. A scope predicate can
      # reveal facts about fields the actor cannot read, so it is granted apart
      # from index/read/search/sort.
      def named_scopes(context:, resource:)
        []
      end

      # Capturing/viewing a fixed selection is independent of list/read/write.
      def select_records?(context:, resource:)
        false
      end

      # Exposes this resource to the admin assistant's tools. Human read grants
      # still apply to every tool call; this grant only decides whether the
      # model may see the resource at all. The assistant is available to an
      # actor when at least one resource grants it.
      def assistant?(context:, resource:)
        false
      end

      # Downloads the current list as CSV. Rows, columns and values still come
      # from the index, show and read grants; this grant only adds the button.
      def export_records?(context:, resource:)
        false
      end

      # Creates records from an uploaded CSV file. Each row still needs the
      # create grant, write field grants and validations.
      def import_records?(context:, resource:)
        false
      end

      # Lists this resource's audit events on the audit log page, across
      # records and actors of the current tenant. Field names still follow the
      # read and write grants.
      def view_audit_log?(context:, resource:)
        false
      end

      # Shows a record's change history (who changed it, when, which fields).
      # Field names are filtered to the actor's current read and write grants;
      # this grant only decides whether the page exists for the record.
      def view_history?(context:, resource:, record:)
        false
      end
    end
  end
end
