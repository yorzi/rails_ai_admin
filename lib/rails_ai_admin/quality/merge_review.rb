# frozen_string_literal: true

module RailsAiAdmin
  module Quality
    # Reopen a live finding at every handoff. Only the host operation changes
    # records. The encrypted ticket carries identity and versions, never values.
    module MergeReview
      PURPOSE = "rails-ai-admin/quality-merge/v1"
      Comparison = Data.define(:rule, :group, :target_id, :rows, :fields, :counts, :versions, :token)
      module_function

      def merge_rule?(resource, rule)
        return false unless rule.remediation_operation
        RailsAiAdmin.operation_registry.fetch(resource, rule.remediation_operation).merge?
      end

      def group!(access, rule_key, group_key, assistant: false)
        report = Runner.new(access, assistant: assistant).call(rule_key)
        raise AccessDenied unless merge_rule?(access.resource, report.rule)
        group = report.reviews.find { |review| review.key == group_key }
        raise AccessDenied unless group && group.rows.size >= 2 && group.rows.all?(&:can_remediate)
        [ report.rule, group ]
      end

      def compare(access, rule_key, group_key, target_id = nil, assistant: false)
        rule, group = group!(access, rule_key, group_key, assistant: assistant)
        target_id ||= group.rows.first.id
        raise AccessDenied unless group.rows.any? { |row| row.id == target_id }
        records = group.rows.map { |row| access.find!(row.id, action: rule.remediation_operation) }
        scalar_fields = access.resource.fields.select { |field| Runner::EVIDENCE_TYPES.include?(field.scalar_type) }
        names = scalar_fields.map(&:name)
        projections = records.to_h do |record|
          [ record.id.to_s, access.project(record, view: :show, only: names) ]
        end
        fields = scalar_fields.select { |field| projections.values.all? { |values| values.key?(field.name.to_s) } }
        counts = records.to_h { |record| [ record.id.to_s, Presentation::AssociationPanel.visible_counts(access.context, access.resource, record, assistant: assistant) ] }
        ticket = {
          tenant: access.context.tenant_ref, actor: access.context.actor_ref, epoch: access.context.security_version,
          resource: access.resource.key, identity: ResourceIdentity.call(access.resource), operation: rule.remediation_operation,
          rule: rule.key, group: group.key, target: target_id, versions: records.to_h { |record| [ record.id.to_s, RecordVersion.of(record) ] }
        }
        token = encryptor.encrypt_and_sign(ticket, purpose: PURPOSE, expires_in: RailsAiAdmin.configuration.intent_ttl)
        Comparison.new(rule, group, target_id, projections, fields, counts, ticket.fetch(:versions), token)
      end

      def ticket!(token, access, operation, target_id)
        raise AccessDenied unless token.is_a?(String) && token.bytesize.between?(1, 12_000)
        ticket = encryptor.decrypt_and_verify(token, purpose: PURPOSE)
        unless ticket && ticket["tenant"] == access.context.tenant_ref && ticket["resource"] == access.resource.key.to_s &&
            ticket["identity"] == ResourceIdentity.call(access.resource).as_json && ticket["operation"] == operation.to_s && ticket["target"] == target_id.to_s
          raise AccessDenied
        end
        raise AccessDenied if ticket["actor"] == access.context.actor_ref && ticket["epoch"] != access.context.security_version
        ticket
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise AccessDenied
      end

      def confirmed_comparison(access, operation, target_id, token)
        original = ticket!(token, access, operation, target_id)
        comparison = compare(access, original.fetch("rule"), original.fetch("group"), target_id.to_s)
        raise AccessDenied, "CONFLICT" unless comparison.versions == original.fetch("versions")
        comparison
      end

      def resolve!(access, operation, target, token, lock:)
        ticket = ticket!(token, access, operation, target.id)
        versions = ticket.fetch("versions")
        records = versions.keys.sort.map do |id|
          record = access.find!(id, action: operation, lock: lock)
          access.authorize!(:show, record)
          raise AccessDenied, "CONFLICT" unless RecordVersion.of(record) == versions.fetch(id)
          record
        end
        rule, group = group!(access, ticket.fetch("rule"), ticket.fetch("group"))
        raise AccessDenied unless rule.remediation_operation.to_s == operation.to_s
        raise AccessDenied, "CONFLICT" unless group.rows.map(&:id).sort == versions.keys.sort
        records.reject { |record| record.id == target.id }
      end

      def encryptor
        key = Rails.application.key_generator.generate_key(PURPOSE, ActiveSupport::MessageEncryptor.key_len)
        ActiveSupport::MessageEncryptor.new(key, serializer: JSON)
      end
    end
  end
end
