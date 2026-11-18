# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    # One proposed update that sets the same values on every record of a fixed
    # selection. The assistant prepares it; only the person's confirmation on
    # its review page writes, one record at a time through the native update
    # operation, each with its own grant check, version check, transaction and
    # audit event.
    #
    # The proposal travels to the review page as an encrypted token that
    # expires with its selection, so proposed values never appear in a URL or
    # log as text and the page itself writes nothing. The token is a reference,
    # not authority: the page and the confirmation recheck the owner, the
    # selection manifest, every record and every value.
    module BulkChange
      PURPOSE = "rails_ai_admin/bulk_change"
      REVIEW_PURPOSE = "rails_ai_admin/bulk_change_review"
      MAX_TOKEN = 16_384
      DECISIONS = %w[confirm dismiss].freeze
      Proposal = ::Data.define(:selection_ref, :manifest_digest, :resource_key, :values, :context_ref)
      # code is nil when the actor may apply the values to this record now.
      # changes maps readable field names to [before, after]; hidden counts
      # proposed fields the actor cannot read on this record.
      Item = ::Data.define(:target, :record, :changes, :hidden, :code)

      module_function

      def available?
        Selection.table_exists? && Selection.column_names.include?("bulk_change_decision")
      end

      def encode(context:, selection:, resource:, values:, context_ref: nil)
        payload = { "s" => selection.selection_ref, "d" => selection.manifest_digest, "r" => resource.key.to_s, "v" => values,
          "a" => context.actor_ref, "t" => context.tenant_ref, "c" => context_ref }
        encryptor.encrypt_and_sign(payload, purpose: PURPOSE, expires_at: selection.expires_at)
      end

      # Another actor's or tenant's token, an expired one and a forged one are
      # all NOT_FOUND.
      def decode(token, context:)
        raise AccessDenied unless context.is_a?(Context) && token.is_a?(String) && token.bytesize.between?(1, MAX_TOKEN)
        payload = encryptor.decrypt_and_verify(token, purpose: PURPOSE)
        unless payload.is_a?(Hash) && payload["a"] == context.actor_ref && payload["t"] == context.tenant_ref &&
            payload["s"].is_a?(String) && payload["d"].is_a?(String) && payload["r"].is_a?(String) && payload["v"].is_a?(Hash) && payload["v"].any?
          raise AccessDenied
        end
        Proposal.new(payload["s"], payload["d"], payload["r"], payload["v"], payload["c"].is_a?(String) ? payload["c"] : nil)
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature, JSON::ParserError, ArgumentError, TypeError
        raise AccessDenied
      end

      def ensure_open!(selection)
        raise ConfigurationError, "Bulk changes require the bulk change decision migration" unless available?
        raise AccessDenied, "CONFLICT" unless pending_selection(selection).exists?
      end

      # Bind approval to the records shown as ready, even when their grants
      # change without a record-version change between GET and POST.
      def sign_review(selection, token, items)
        review_verifier.generate(review_digest(token, items), expires_at: selection.expires_at, purpose: REVIEW_PURPOSE)
      end

      def verify_review!(signature, token, items)
        raise AccessDenied, "INVALID_QUERY" unless signature.is_a?(String) && signature.bytesize.between?(1, 1024)
        unless review_verifier.verified(signature, purpose: REVIEW_PURPOSE) == review_digest(token, items)
          raise AccessDenied, "CONFLICT"
        end
      end

      def review_digest(token, items) = InputSchema.digest(token: token, ids: items.map { |item| item.target.id })
      def review_verifier = ::Rails.application.message_verifier(REVIEW_PURPOSE)
      private_class_method :review_digest, :review_verifier

      # Claim the first decision before any member writes. The comparison and
      # update are atomic on both supported databases, including for no-op updates.
      def decide!(selection, decision)
        raise AccessDenied, "INVALID_QUERY" unless DECISIONS.include?(decision)
        raise AccessDenied, "CONFLICT" unless pending_selection(selection).update_all(bulk_change_decision: decision) == 1
      end

      def pending_selection(selection)
        Selection.where(id: selection.selection_ref, manifest_digest: selection.manifest_digest, bulk_change_decision: nil)
          .where(Selection.arel_table[:expires_at].gt(Time.current))
      end
      private_class_method :pending_selection

      # For each selected record, whether the actor may apply the values now
      # and what visibly changes. Runner#preview writes nothing; it checks the
      # record's scope, update grant, version and each value as a form would.
      def plan(context:, resource:, selection:, records:, values:)
        runner = Runner.new
        access = Authorization::Access.new(context, resource)
        selection.targets.map do |target|
          record = records[target.id]
          preview = runner.preview(context: context, resource: resource, operation: "update", target_id: target.id,
            expected_version: target.expected_version, input: values, origin: :assistant)
          next Item.new(target, record, {}, 0, preview.code) if preview.is_a?(Result)
          changes, hidden = changes(access, record, preview.values)
          Item.new(target, record, changes, hidden, nil)
        rescue AccessDenied => error
          Item.new(target, record, {}, 0, error.code == "CONFLICT" ? "CONFLICT" : "NOT_FOUND")
        end
      end

      def changes(access, record, values)
        readable = access.fields(:read, record, view: :show).index_by { |field| field.name.to_s }
        before = access.project(record, view: :show)
        shown = values.keys.map(&:to_s).select { |name| readable.key?(name) && before.key?(name) }
        [ shown.to_h { |name| [ name, [ before[name], values[name] ] ] }, values.size - shown.size ]
      rescue AccessDenied
        [ {}, values.size ]
      end

      def encryptor
        unless defined?(::Rails) && ::Rails.application&.respond_to?(:key_generator) && ::Rails.application.secret_key_base.present?
          raise ConfigurationError, "Bulk changes need the application's secret_key_base"
        end
        secret = ::Rails.application.key_generator.generate_key(PURPOSE, ActiveSupport::MessageEncryptor.key_len)
        ActiveSupport::MessageEncryptor.new(secret, serializer: JSON)
      end
    end
  end
end
