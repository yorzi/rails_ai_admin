# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Selections
    # Captures exact scoped targets; never saves a query to expand during execution.
    class Builder
      LIMIT = 100
      Target = Data.define(:id, :expected_version, :label)
      Snapshot = Data.define(:selection_ref, :resource_key, :manifest_digest, :expires_at, :targets)

      def capture(context:, resource:, target_ids:)
        access = Authorization::Access.new(context, resource)
        raise AccessDenied unless RailsAiAdmin.registry.fetch(resource.key).equal?(resource)
        ensure_storage!(resource)
        targets = ActiveRecord::Base.while_preventing_writes do
          access.authorize_selection!
          ids = canonical_ids(resource, target_ids)
          records = scoped_records(access, ids)
          records.map { |record| target(access, record) }.sort_by(&:id).freeze
        end
        version = resource_version(resource)
        selection = Selection.transaction(requires_new: true) do
          row = Selection.create!(id: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
            security_version: context.security_version, resource_key: resource.key.to_s, resource_version: version,
            manifest_digest: manifest_digest(version, targets), item_count: targets.size,
            expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
          SelectionItem.insert_all!(targets.each_with_index.map { |item, position| { selection_id: row.id,
            target_id: item.id, expected_version: item.expected_version, position: position } })
          row
        end
        raise ConfigurationError, "Selection creation was rolled back" unless selection
        snapshot(selection, targets)
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Selection lookup must be read-only", cause: nil
      end

      # This is a fresh check, not a lock or authorization for a later write.
      # Execution must bind this digest and recheck each item in its transaction.
      def revalidate(context:, selection_ref:, resource: nil, manifest_digest: nil)
        read_snapshot(context: context, selection_ref: selection_ref, resource: resource, manifest_digest: manifest_digest, labels: true)
      end

      # Internal admission path: no title projection or domain preflight under
      # the parent lock. Only exact target checks and the given authorization run.
      def validate_for_admission(context:, selection_ref:, resource:, manifest_digest:, &authorize_target)
        read_snapshot(context: context, selection_ref: selection_ref, resource: resource, manifest_digest: manifest_digest, labels: false, &authorize_target)
      end

      private

      def read_snapshot(context:, selection_ref:, resource:, manifest_digest:, labels:)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        unless selection_ref.is_a?(String) && selection_ref.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
          raise AccessDenied
        end
        selection = Selection.find_by(id: selection_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
        raise AccessDenied unless selection
        raise AccessDenied, "SELECTION_INVALIDATED" unless selection.security_version == context.security_version
        raise AccessDenied, "SELECTION_EXPIRED" unless selection.expires_at > Time.current
        registered = RailsAiAdmin.registry.fetch(selection.resource_key)
        raise AccessDenied unless resource.nil? || registered.equal?(resource)
        ensure_storage!(registered)
        raise AccessDenied, "SELECTION_INVALIDATED" unless selection.resource_version == resource_version(registered)
        items = SelectionItem.where(selection_id: selection.id).order(:position).limit(LIMIT + 1).to_a
        verify_manifest!(selection, items)
        raise AccessDenied, "SELECTION_INVALIDATED" if manifest_digest && manifest_digest != selection.manifest_digest
        access = Authorization::Access.new(context, registered)
        targets = ActiveRecord::Base.while_preventing_writes do
          access.authorize_selection!
          records = scoped_records(access, items.map(&:target_id)).index_by { |record| record.id.to_s }
          items.map do |item|
            record = records.fetch(item.target_id)
            access.authorize!(:show, record)
            raise AccessDenied, "CONFLICT" unless record.lock_version == item.expected_version
            value = target(access, record, labels: labels, authorized: true)
            yield record if block_given?
            value
          end.freeze
        end
        snapshot(selection, targets)
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Selection lookup must be read-only", cause: nil
      end

      private

      def ensure_storage!(resource)
        model = resource.model_class
        unless [ Selection, SelectionItem ].all? { |klass| klass.connection_pool.equal?(model.connection_pool) } &&
            model.locking_enabled? && model.locking_column == "lock_version" && !model.composite_primary_key? &&
            %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Selections require one SQLite/PostgreSQL pool, a single primary key and lock_version"
        end
      end

      def canonical_ids(resource, values)
        unless values.is_a?(Array) && values.size.between?(1, LIMIT)
          raise AccessDenied, "INVALID_QUERY"
        end
        type = resource.model_class.type_for_attribute(resource.model_class.primary_key)
        unless %i[integer string uuid].include?(type.type)
          raise ConfigurationError, "Selection primary keys must be integer, string or UUID"
        end
        ids = values.map do |value|
          unless (value.is_a?(String) || value.is_a?(Integer)) && value.to_s.bytesize.between?(1, 150) && !value.to_s.match?(/[[:cntrl:]]/) &&
              (type.type != :integer || value.to_s.match?(/\A[+-]?\d+\z/))
            raise AccessDenied, "INVALID_QUERY"
          end
          cast = type.cast(value)
          raise AccessDenied, "INVALID_QUERY" if cast.nil? || cast.to_s.bytesize > 150
          cast.to_s
        end
        raise AccessDenied, "INVALID_QUERY" unless ids.uniq.size == ids.size
        ids
      end

      def scoped_records(access, ids)
        model = access.resource.model_class
        primary_key = model.arel_table[model.primary_key]
        authorized_ids = access.relation.where(primary_key.in(ids)).reorder(nil).select(primary_key).distinct
        # Reconstitute only IDs selected by the complete authorized relation.
        # DISTINCT on model.* fails for PostgreSQL JSON columns; deduplicate IDs
        # inside the scoped subquery before applying the outer bound instead.
        records = model.unscoped.where(model.primary_key => authorized_ids).order(primary_key.asc).limit(LIMIT + 1).to_a
        raise AccessDenied unless records.map { |record| record.id.to_s }.sort == ids.sort
        records
      end

      def target(access, record, labels: true, authorized: false)
        access.authorize!(:show, record) unless authorized
        version = record.lock_version
        raise ConfigurationError, "Selection versions must be nonnegative integers" unless version.is_a?(Integer) && version >= 0
        label = labels ? access.record_label(record) : "Record ##{record.id}"
        Target.new(record.id.to_s.freeze, version, label.freeze)
      end

      def resource_version(resource)
        InputSchema.digest(key: resource.key, identity: ResourceIdentity.call(resource), policy: resource.policy, readonly: resource.readonly?,
          adapter: RailsAiAdmin.configuration.authorization_adapter, fields: resource.fields.map(&:contract))
      end

      def manifest_digest(version, targets)
        InputSchema.digest(resource_version: version, targets: targets.map { |item| [ item.id, item.expected_version ] })
      end

      def verify_manifest!(selection, items)
        unless selection.item_count.between?(1, LIMIT) && items.size == selection.item_count && items.map(&:position) == (0...items.size).to_a &&
            items.map(&:target_id).uniq.size == items.size && selection.manifest_digest == InputSchema.digest(resource_version: selection.resource_version,
              targets: items.map { |item| [ item.target_id, item.expected_version ] })
          raise ConfigurationError, "Selection manifest is inconsistent"
        end
      end

      def snapshot(selection, targets)
        Snapshot.new(selection.id.freeze, selection.resource_key.freeze, selection.manifest_digest.freeze, selection.expires_at, targets)
      end
    end
  end
end
