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

      # action is :read, :write, :search or :sort; no implicit grants.
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

      # Capturing/viewing a fixed selection is independent of list/read/write.
      def select_records?(context:, resource:)
        false
      end
    end
  end
end
