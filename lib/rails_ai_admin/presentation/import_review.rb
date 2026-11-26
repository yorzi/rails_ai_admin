# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    class ImportReview
      SYNC_LIMIT = 100
      Row = Data.define(:number, :input, :result, :duplicate, :excluded, :formula)
      Preview = Data.define(:headers, :samples, :rows, :digest, :selected, :ready)

      attr_reader :limit

      def initialize(context, resource)
        @context, @resource = context, resource
        @access = Authorization::Access.new(context, resource)
        limit = RailsAiAdmin.configuration.import_limit
        @limit = ImportBatch.available? ? limit : [ SYNC_LIMIT, limit ].min
        @import = CsvImport.new(context, resource, limit: @limit)
        @runner = Operations::Runner.new
      end

      def create(text, filename)
        text = text.dup.force_encoding(Encoding::UTF_8)
        headers, rows = @import.read(text)
        id = SecureRandom.uuid
        mapping = @import.map_columns(headers, manual: true).transform_keys(&:to_s).transform_values { |f| f.name.to_s }
        basename = File.basename(filename.to_s.encode("UTF-8", invalid: :replace, undef: :replace))
        ImportDraft.create!(**owner, id: id, filename: basename.gsub(/[[:cntrl:]]/, "").first(160),
          resource_signature: signature, row_count: rows.size, mapping: mapping, excluded: [], expires_at: 30.minutes.from_now,
          payload_blob: ImportDraft.encryptor.encrypt_and_sign(text, purpose: id))
      end

      def find!(id)
        @access.authorize_import!
        draft = ImportDraft.where(owner).where("expires_at > ?", Time.current).find_by(id: id)
        raise AccessDenied unless draft && draft.id == id && owner.all? { |key, value| draft[key] == value } && draft.resource_signature == signature
        draft
      end

      def match_fields
        @access.authorize!(:index)
        @import.fields & @access.fields(:filter).select { |field| field.filter_operators.include?(:eq) }
      rescue AccessDenied
        []
      end

      def preview(draft)
        check_draft!(draft)
        headers, data = @import.read(ImportDraft.encryptor.decrypt_and_verify(draft.payload_blob, purpose: draft.id))
        mapping = resolve_mapping(draft.mapping, headers.size)
        match = match_fields.find { |field| field.name.to_s == draft.match_field } if draft.match_field
        raise AccessDenied if draft.match_field && (!match || !mapping.value?(match))
        seen = Set.new
        rows = data.map.with_index(2) do |cells, number|
          input = @import.row_input(cells, mapping)
          excluded = draft.excluded.include?(number)
          checked, duplicate = check_row(input, match, seen, excluded)
          Row.new(number, input, checked, duplicate, excluded, cells.any? { |cell| cell.start_with?("=", "+", "-", "@", "\t", "\r") })
        end
        selected = rows.reject { |row| row.excluded || row.duplicate && draft.duplicates == "skip" }
        digest = InputSchema.digest([ draft.id, @context.time_zone, draft.security_version, draft.mapping, draft.match_field, draft.duplicates, draft.excluded,
          rows.map { |row| [ row.number, row.input, row.result.code, row.duplicate ] } ])
        samples = headers.each_index.map { |index| data.first(3).filter_map { |cells| cells[index].presence&.truncate(60) } }
        Preview.new(headers, samples, rows, digest, selected, mapping.any? && selected.any? && selected.all? { |row| row.result.success? })
      rescue CsvImport::Invalid
        raise AccessDenied, "CONFLICT", cause: nil
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise AccessDenied
      end

      def revise!(draft, digest, mapping:, excluded:, match_field:, duplicates:)
        with_draft_lock(draft) do
          current = preview(draft)
          check_digest!(current.digest, digest)
          resolve_mapping(mapping, current.headers.size)
          unless excluded.is_a?(Array) && excluded.size <= draft.row_count && excluded.all? { |n| n.is_a?(String) && n.to_i.to_s == n && n.to_i.between?(2, draft.row_count + 1) }
            raise AccessDenied, "INVALID_QUERY"
          end
          unless %w[skip create].include?(duplicates) && (match_field.nil? || match_fields.any? { |f| f.name.to_s == match_field } && mapping.value?(match_field))
            raise AccessDenied, "INVALID_QUERY"
          end
          draft.update!(mapping: mapping.reject { |_, value| value == "" }, excluded: excluded.map(&:to_i).uniq.sort,
            match_field: match_field, duplicates: duplicates)
          preview(draft)
        end
      end

      def confirm!(draft, digest, choices: nil)
        with_draft_lock(draft) do
          raise AccessDenied unless draft.expires_at.future?
          if choices
            same = choices[:mapping].reject { |_, name| name == "" } == draft.mapping && choices[:match_field] == draft.match_field &&
              choices[:duplicates] == draft.duplicates && choices[:excluded].is_a?(Array) && choices[:excluded].all?(String) && choices[:excluded].sort == draft.excluded.map(&:to_s).sort
            raise AccessDenied, "CONFLICT" unless same
          end
          if draft.status == "admitted"
            check_digest!(draft.confirmed_digest, digest)
            next
          end
          current = preview(draft)
          check_digest!(current.digest, digest)
          raise AccessDenied, "INVALID_QUERY" unless current.ready
          # Take a write claim before the first domain change, including on SQLite.
          draft.update!(status: "admitted", confirmed_digest: digest)
          if current.selected.size > SYNC_LIMIT
            ImportBatch.admit!(draft, @context, current.selected)
            next
          end
          current.selected.each do |row|
            intent = @runner.prepare(context: @context, resource: @resource, operation: :create)
            result = @runner.execute(context: @context, intent_ref: intent.id, input: row.input, human_confirmed: true)
            raise AccessDenied, "CONFLICT" unless result.success?
          end
          draft.update!(created_count: current.selected.size, payload_blob: nil)
        end
      end

      def batch_fields(draft)
        resolve_mapping(draft.mapping, CsvImport::MAX_COLUMNS).values
      end

      def authorize_batch!(draft)
        @access.authorize_import!
        @access.authorize!(:create, @access.relation.new)
        raise AccessDenied unless draft.status == "admitted" && draft.expires_at.future? && draft.try(:execution_zone) == @context.time_zone && ImportRow.table_exists? &&
          owner.all? { |key, value| draft[key] == value } && draft.resource_signature == signature
        batch_fields(draft)
      end

      def duplicate_now?(draft, input)
        return false unless draft.match_field && draft.duplicates == "skip"
        field = match_fields.find { |entry| entry.name.to_s == draft.match_field }
        raise AccessDenied unless field
        wire = input[field.name.to_s]
        wire.present? && existing_match?(field, wire)
      end

      def check_digest!(expected, supplied)
        raise AccessDenied, "CONFLICT" unless supplied.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
      end

      private

      def owner
        { actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref, security_version: @context.security_version, resource_key: @resource.key.to_s }
      end

      def signature
        definition = RailsAiAdmin.operation_registry.fetch(@resource, :create)
        InputSchema.digest(Operations::RunnerFingerprint.call(@resource, definition))
      end

      def check_draft!(draft)
        raise AccessDenied unless draft.status == "draft" && draft.expires_at.future?
      end

      def resolve_mapping(mapping, size)
        raise AccessDenied, "INVALID_QUERY" unless mapping.is_a?(Hash) && mapping.size <= size
        fields = @import.fields.index_by { |field| field.name.to_s }
        resolved = {}
        mapping.each do |position, name|
          unless position.is_a?(String) && position.to_i.to_s == position && position.to_i.between?(0, size - 1)
            raise AccessDenied, "INVALID_QUERY"
          end
          next if name == ""
          field = fields[name]
          raise AccessDenied, "INVALID_QUERY" unless field && !resolved.value?(field)
          resolved[position.to_i] = field
        end
        resolved
      end

      def with_draft_lock(draft, &block)
        draft.with_lock(&block)
      rescue ActiveRecord::StatementInvalid => error
        raise unless Collections::Contract.contention?(error)
        raise AccessDenied, "CONFLICT", cause: nil
      end

      def check_row(input, match, seen, excluded)
        result = @runner.validate_create(context: @context, resource: @resource, input: input)
        return [ result, false ] unless match && result.success? && (wire = input[match.name.to_s]).present?
        value = Queries::List.filter_value(match, "eq", wire, time_zone: @context.time_zone)
        duplicate = seen.include?(value) || existing_match?(match, wire)
        seen.add(value) unless excluded
        [ result, duplicate ]
      rescue AccessDenied => error
        [ Operations::Result.new(code: error.code), false ]
      end

      def existing_match?(field, wire)
        Queries::List.new(@context, @resource).relation(scope: Queries::NamedScope::NONE,
          filters: { field.name.to_s => { "eq" => wire } }).exists?
      end
    end
  end
end
