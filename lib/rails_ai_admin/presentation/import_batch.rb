# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    module ImportBatch
      CHUNK = 25
      module_function

      def available?
        RailsAiAdmin.configuration.context_adapter&.constantize&.method_defined?(:resolve_job) && ImportRow.table_exists?
      end

      def admit!(draft, context, selected)
        attrs = selected.map do |row|
          { draft_id: draft.id, number: row.number, input_blob: ImportDraft.encryptor.encrypt_and_sign(row.input, purpose: "#{draft.id}/#{row.number}") }
        end
        attrs.each_slice(100) { |slice| ImportRow.insert_all!(slice) }
        draft.update!(created_count: 0, execution_zone: context.time_zone, payload_blob: nil, expires_at: 24.hours.from_now)
      end

      def process(id)
        draft = ImportDraft.find_by(id: id)
        return unless draft
        CHUNK.times do
          done = draft.with_lock do
            row = draft.rows.where(status: "queued").order(:number).first
            next true unless row
            if draft.expires_at.past?
              fail_pending(draft, "APPROVAL_EXPIRED")
              next true
            end
            # The domain create, its audit receipt and the row transition
            # commit together under the same draft lock on both databases.
            begin
              context = resolve!(draft)
              resource = RailsAiAdmin.registry.fetch(draft.resource_key)
              review = ImportReview.new(context, resource)
              review.authorize_batch!(draft)
              input = row.input
              if review.duplicate_now?(draft, input)
                row.update!(status: "skipped", input_blob: nil)
              else
                create_row(context, resource, draft, row, input)
              end
            rescue AccessDenied => error
              fail_pending(draft, error.code)
            end
            false
          end
          break if done
        end
        draft.rows.where(status: "queued").exists?
      rescue ActiveRecord::RecordNotFound
        false
      end

      def resolve!(draft)
        resolver = RailsAiAdmin.configuration.context_adapter&.constantize&.new
        context = resolver&.resolve_job(actor_ref: draft.actor_ref, tenant_ref: draft.tenant_ref, security_version: draft.security_version) if resolver.respond_to?(:resolve_job)
        unless context.is_a?(Context) && context.actor_ref == draft.actor_ref && context.tenant_ref == draft.tenant_ref &&
            context.security_version == draft.security_version && context.time_zone == draft.execution_zone
          raise AccessDenied
        end
        context
      end

      def create_row(context, resource, draft, row, input)
        runner = Operations::Runner.new
        intent = runner.prepare(context: context, resource: resource, operation: :create)
        result = runner.execute(context: context, intent_ref: intent.id, input: input, human_confirmed: true)
        row.attempts += 1
        if result.success?
          row.update!(status: "created", input_blob: nil)
          draft.update!(created_count: draft.created_count + 1)
        else
          row.update!(status: "failed", error_code: result.code)
        end
      end

      def fail_pending(draft, code)
        draft.rows.where(status: "queued").update_all(status: "failed", error_code: code, updated_at: Time.current)
      end

      def retry_digest(draft)
        InputSchema.digest([ draft.confirmed_digest, draft.rows.where(status: "failed").order(:number).pluck(:id, :attempts, :error_code, :updated_at).map { |id, attempts, code, at| [ id, attempts, code, at.utc.iso8601(6) ] } ])
      end

      def retry!(review, draft, digest)
        draft.with_lock do
          review.authorize_batch!(draft)
          raise AccessDenied, "CONFLICT" if draft.rows.where(status: "queued").exists?
          review.check_digest!(retry_digest(draft), digest)
          failed = draft.rows.where(status: "failed")
          raise AccessDenied, "CONFLICT" unless failed.exists?
          failed.update_all(status: "queued", error_code: nil, updated_at: Time.current)
        end
      end

      def failed_csv(review, draft)
        review.authorize_batch!(draft)
        names = review.batch_fields(draft).map { |field| field.name.to_s }
        lines = [ CsvExport.line(names) ]
        draft.rows.where(status: "failed").order(:number).each do |row|
          input = row.input
          cells = names.map do |name|
            text = input[name].to_s
            text.match?(CsvExport::FORMULA) ? "'#{text}" : text
          end
          lines << CsvExport.line(cells)
        end
        "﻿#{lines.join}"
      end
    end
  end
end
