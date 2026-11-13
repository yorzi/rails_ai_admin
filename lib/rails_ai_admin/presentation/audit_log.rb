# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Recent audit events across the resources whose view_audit_log? grant
    # this actor holds, for the current tenant only. Field names follow each
    # resource's current read and write grants; the rest are counted.
    class AuditLog
      PAGE_SIZE = 50
      STATUSES = %w[succeeded rejected].freeze
      Entry = Data.define(:id, :at, :resource, :record_id, :operation, :status, :code, :origin, :actor_ref, :fields, :hidden_fields)
      Page = Data.define(:entries, :older)
      CURSOR = /\A[1-9][0-9]{0,18}\z/

      attr_reader :resources

      def initialize(context)
        @context = context
        @resources = RailsAiAdmin.registry.resources.select do |resource|
          Authorization::Access.new(context, resource).authorize_audit_log!
        rescue AccessDenied
          false
        end
        raise AccessDenied if @resources.empty?
      end

      # Filters are exact values; unknown ones are an invalid query.
      def page(resource: nil, operation: nil, status: nil, actor: nil, before: nil)
        keys = @resources.map { |entry| entry.key.to_s }
        valid = (resource.nil? || keys.include?(resource)) && (status.nil? || STATUSES.include?(status)) &&
          (operation.nil? || operation.is_a?(String) && operation.match?(/\A[a-z][a-z0-9_]{0,63}\z/)) &&
          (actor.nil? || actor.is_a?(String) && actor.bytesize <= 150 && !actor.match?(/[[:cntrl:]]/)) &&
          (before.nil? || before.is_a?(String) && before.match?(CURSOR))
        raise AccessDenied, "INVALID_QUERY" unless valid
        scope = AuditEvent.where(tenant_ref: @context.tenant_ref, resource_key: resource || keys)
        scope = scope.where(operation: operation) if operation
        scope = scope.where(status: status) if status
        scope = scope.where(actor_ref: actor) if actor
        scope = scope.where(AuditEvent.arel_table[:id].lt(Integer(before, 10))) if before
        events = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
        by_key = @resources.index_by { |entry| entry.key.to_s }
        labels = Hash.new { |hash, key| hash[key] = visible_labels(by_key.fetch(key)) }
        entries = events.first(PAGE_SIZE).map do |event|
          names = Array(event.changed_fields).grep(String)
          shown = names.filter_map { |name| labels[event.resource_key][name] }
          Entry.new(event.id, event.created_at, by_key.fetch(event.resource_key), event.record_id, event.operation, event.status,
            event.code, event.origin, event.actor_ref, shown.freeze, names.size - shown.size)
        end
        Page.new(entries.freeze, events.size > PAGE_SIZE ? entries.last.id : nil)
      end

      private

      def visible_labels(resource)
        access = Authorization::Access.new(@context, resource)
        fields = access.fields(:read) | access.fields(:write, operation: :update)
        fields.to_h { |field| [ field.name.to_s, field.label ] }
      rescue AccessDenied
        {}
      end
    end
  end
end
