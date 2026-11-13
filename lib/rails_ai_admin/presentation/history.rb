# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # One record's audit trail for its history page. It reads only the
    # current tenant's events for this resource and record, and names only
    # fields the actor may currently read or write.
    class History
      PAGE_SIZE = 50
      Entry = Data.define(:id, :at, :operation, :status, :code, :origin, :actor_ref, :fields, :hidden_fields)
      Page = Data.define(:entries, :older)

      def initialize(access, record)
        @access, @record = access, record
        access.authorize_history!(record)
      end

      # before: the id of the oldest entry already shown (canonical integer text).
      def page(before: nil)
        unless before.nil? || before.is_a?(String) && before.match?(/\A[1-9][0-9]{0,18}\z/)
          raise AccessDenied, "INVALID_QUERY"
        end
        scope = AuditEvent.where(tenant_ref: @access.context.tenant_ref, resource_key: @access.resource.key.to_s, record_id: @record.id.to_s)
        scope = scope.where(AuditEvent.arel_table[:id].lt(Integer(before, 10))) if before
        events = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
        labels = visible_labels
        entries = events.first(PAGE_SIZE).map do |event|
          names = Array(event.changed_fields).grep(String)
          shown = names.filter_map { |name| labels[name] }
          Entry.new(event.id, event.created_at, event.operation, event.status, event.code, event.origin,
            event.actor_ref, shown.freeze, names.size - shown.size)
        end
        Page.new(entries.freeze, events.size > PAGE_SIZE ? entries.last.id : nil)
      end

      private

      def visible_labels
        fields = @access.fields(:read, @record) | @access.fields(:write, @record, operation: :update)
        fields.to_h { |field| [ field.name.to_s, field.label ] }
      rescue AccessDenied
        {}
      end
    end
  end
end
