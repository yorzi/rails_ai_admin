# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Selections
    # Captures exact scoped targets; never saves a query to expand during execution.
    class Builder
      LIMIT = 100
      SYNC_LIMIT = LIMIT
      MAX_ASYNC_LIMIT = 10_000
      INSERT_BATCH_SIZE = 500
      Target = Data.define(:id, :expected_version, :label)

      # The largest selection a background run may capture: the configured
      # async_bulk_limit once the 0.7 bounds migration has widened the table
      # constraints (it also adds retry_of_run_id), otherwise the old 100.
      def self.async_limit
        widened = OperationRun.column_names.include?("retry_of_run_id")
        widened ? RailsAiAdmin.configuration.async_bulk_limit : LIMIT
      rescue ActiveRecord::ActiveRecordError
        LIMIT
      end
      Snapshot = Data.define(:selection_ref, :resource_key, :manifest_digest, :expires_at, :targets)

      def capture(context:, resource:, target_ids:, max_items: LIMIT)
        raise ConfigurationError, "Selection bound must be between 1 and #{MAX_ASYNC_LIMIT}" unless max_items.is_a?(Integer) && max_items.between?(1, MAX_ASYNC_LIMIT)
        access = Authorization::Access.new(context, resource)
        raise AccessDenied unless RailsAiAdmin.registry.fetch(resource.key).equal?(resource)
        ensure_storage!(resource)
        targets = ActiveRecord::Base.while_preventing_writes do
          access.authorize_selection!
          ids = canonical_ids(resource, target_ids, max_items: max_items)
          records = scoped_records(access, ids, limit: max_items)
          records.map { |record| target(access, record) }.sort_by(&:id).freeze
        end
        version = resource_version(resource)
        selection = Selection.transaction(requires_new: true) do
          row = Selection.create!(id: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
            security_version: context.security_version, resource_key: resource.key.to_s, resource_version: version,
            manifest_digest: manifest_digest(version, targets), item_count: targets.size,
            expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
          rows = targets.each_with_index.map do |item, position|
            { selection_id: row.id, target_id: item.id, expected_version: item.expected_version, position: position }
          end
          rows.each_slice(INSERT_BATCH_SIZE) { |slice| SelectionItem.insert_all!(slice) }
          row
        end
        raise ConfigurationError, "Selection creation was rolled back" unless selection
        snapshot(selection, targets)
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Selection lookup must be read-only", cause: nil
      end

      # This is a fresh check, not a lock or authorization for a later write.
      # Execution must bind this digest and recheck each item in its transaction.
      # A block receives each current record, inside the same read-only check.
      def revalidate(context:, selection_ref:, resource: nil, manifest_digest: nil, max_items: MAX_ASYNC_LIMIT, &block)
        read_snapshot(context: context, selection_ref: selection_ref, resource: resource,
          manifest_digest: manifest_digest, labels: true, max_items: max_items, &block)
      end

      # Internal admission path: no title projection or domain preflight under
      # the parent lock. Only exact target checks and the given authorization run.
      def validate_for_admission(context:, selection_ref:, resource:, manifest_digest:, allow_reviewer: false, max_items: MAX_ASYNC_LIMIT, &authorize_target)
        read_snapshot(context: context, selection_ref: selection_ref, resource: resource, manifest_digest: manifest_digest,
          labels: false, allow_reviewer: allow_reviewer, max_items: max_items, &authorize_target)
      end

      private

      def read_snapshot(context:, selection_ref:, resource:, manifest_digest:, labels:, allow_reviewer: false, max_items: MAX_ASYNC_LIMIT)
        raise ConfigurationError, "Selection bound must be between 1 and #{MAX_ASYNC_LIMIT}" unless max_items.is_a?(Integer) && max_items.between?(1, MAX_ASYNC_LIMIT)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        unless selection_ref.is_a?(String) && selection_ref.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
          raise AccessDenied
        end
        selection = if allow_reviewer
          Selection.find_by(id: selection_ref, tenant_ref: context.tenant_ref)
        else
          Selection.find_by(id: selection_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
        end
        raise AccessDenied unless selection
        raise AccessDenied, "SELECTION_INVALIDATED" if !allow_reviewer && selection.security_version != context.security_version
        raise AccessDenied, "SELECTION_EXPIRED" unless selection.expires_at > Time.current
        registered = RailsAiAdmin.registry.fetch(selection.resource_key)
        raise AccessDenied unless resource.nil? || registered.equal?(resource)
        ensure_storage!(registered)
        raise AccessDenied, "SELECTION_INVALIDATED" unless selection.resource_version == resource_version(registered)
        items = SelectionItem.where(selection_id: selection.id).order(:position).limit(MAX_ASYNC_LIMIT + 1).to_a
        verify_manifest!(selection, items)
        raise AccessDenied, "INVALID_QUERY" if selection.item_count > max_items
        raise AccessDenied, "SELECTION_INVALIDATED" if manifest_digest && manifest_digest != selection.manifest_digest
        access = Authorization::Access.new(context, registered)
        targets = ActiveRecord::Base.while_preventing_writes do
          access.authorize_selection!
          records = scoped_records(access, items.map(&:target_id), limit: max_items).index_by { |record| record.id.to_s }
          items.map do |item|
            record = records.fetch(item.target_id)
            access.authorize!(:show, record)
            raise AccessDenied, "CONFLICT" unless RecordVersion.of(record) == item.expected_version
            value = target(access, record, labels: labels, authorized: true)
            yield record if block_given?
            value
          end.freeze
        end
        snapshot(selection, targets)
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Selection lookup must be read-only", cause: nil
      end

      def ensure_storage!(resource)
        model = resource.model_class
        unless [ Selection, SelectionItem ].all? { |klass| klass.connection_pool.equal?(model.connection_pool) } &&
            RecordVersion.supported?(model) &&
            %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Selections require one SQLite/PostgreSQL pool, a single primary key and lock_version or updated_at"
        end
      end

      def canonical_ids(resource, values, max_items: LIMIT)
        unless values.is_a?(Array) && values.size.between?(1, max_items)
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
        # A repeated box (or "1" and "01") is one target, not an invalid query (RAA-013).
        ids.uniq
      end

      def scoped_records(access, ids, limit: LIMIT)
        model = access.resource.model_class
        primary_key = model.arel_table[model.primary_key]
        authorized_ids = access.relation.where(primary_key.in(ids)).reorder(nil).select(primary_key).distinct
        # Reconstitute only IDs selected by the complete authorized relation.
        # DISTINCT on model.* fails for PostgreSQL JSON columns; deduplicate IDs
        # inside the scoped subquery before applying the outer bound instead.
        records = model.unscoped.where(model.primary_key => authorized_ids).order(primary_key.asc).limit(limit + 1).to_a
        raise AccessDenied unless records.map { |record| record.id.to_s }.sort == ids.sort
        records
      end

      def target(access, record, labels: true, authorized: false)
        access.authorize!(:show, record) unless authorized
        version = RecordVersion.of(record)
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
        unless selection.item_count.between?(1, MAX_ASYNC_LIMIT) && items.size == selection.item_count && items.map(&:position) == (0...items.size).to_a &&
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
