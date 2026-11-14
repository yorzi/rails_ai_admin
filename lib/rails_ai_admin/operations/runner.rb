# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Operations
    # Executes registered database operations through one atomic boundary.
    class Runner
      ORIGINS = %w[ui surface assistant].freeze
      Proposal = Data.define(:intent, :values, :changes)
      Preview = Data.define(:target_id, :expected_version, :values, :changes)

      def prepare(...)
        result = preflight(...)
        raise AccessDenied, result.code if result.is_a?(Result)
        result.intent
      end

      # intent_id lets a replay-safe adapter (an assistant tool call) derive one
      # stable intent per call; it must be a UUID and creates no authority.
      def preflight(context:, resource:, operation:, target_id: nil, expected_version: nil, input: nil, origin: :ui, intent_id: nil)
        unless intent_id.nil? || intent_id.is_a?(String) && intent_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
          raise ConfigurationError, "intent_id must be a lowercase UUID"
        end
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        if definition.custom? && definition.scope == :collection
          raise ConfigurationError, "Collection intents require fixed-manifest preflight and admission"
        end
        result = preview(context: context, resource: resource, operation: operation, target_id: target_id,
          expected_version: expected_version, input: input, origin: origin)
        return result if result.is_a?(Result)
        intent = OperationRun.create!(id: intent_id || SecureRandom.uuid, actor_ref: context.actor_ref,
          tenant_ref: context.tenant_ref, security_version: context.security_version,
          resource_key: resource.key.to_s, operation: operation.to_s,
          operation_version: operation_version(resource, operation), target_id: result.target_id,
          expected_version: result.expected_version, input_digest: input && InputSchema.digest(result.values),
          origin: origin.to_s, expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
        Proposal.new(intent, result.values, result.changes)
      end

      FormSession = Data.define(:intent, :record)
      FORM_RECOVERY_WINDOW = 1.hour
      # id is the future OperationRun id; ref is what the form submits.
      FormReference = Data.define(:id, :ref)

      # Native form pages run the same checks as prepare but write nothing.
      # The signed reference becomes an intent on first submit (ADR 0025).
      def issue_form_intent(context:, resource:, operation:, target_id: nil, expected_version: nil)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        raise ConfigurationError, "Form intents cover built-in create, update and destroy" if definition.custom?
        result = preview(context: context, resource: resource, operation: operation, target_id: target_id,
          expected_version: expected_version, origin: :ui)
        raise AccessDenied, result.code if result.is_a?(Result)
        now = Time.current
        id = SecureRandom.uuid
        ref = FormIntent.generate({ id: id, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          security_version: context.security_version, resource_key: resource.key.to_s, operation: operation.to_s,
          operation_version: operation_version(resource, operation), target_id: result.target_id,
          expected_version: result.expected_version, created_at: now.utc.iso8601(6),
          expires_at: (now + RailsAiAdmin.configuration.intent_ttl).utc.iso8601(6) }, recovery_window: FORM_RECOVERY_WINDOW)
        FormReference.new(id, ref)
      end

      # Turns a submitted form reference into its OperationRun id, creating the
      # proposed row from the signed payload the first time. A UUID passes
      # through unchanged; anything unverifiable, or another owner's reference,
      # returns nil. The row commits on its own so a rejected submit keeps the
      # same intent for the next attempt, exactly as a GET-created one did.
      def materialize_form_intent(context:, reference:)
        return reference if FormIntent.uuid?(reference)
        payload = FormIntent.verify(reference)
        return unless payload && context.is_a?(Context) && payload["actor_ref"] == context.actor_ref && payload["tenant_ref"] == context.tenant_ref
        unless OperationRun.exists?(id: payload["id"])
          OperationRun.transaction(requires_new: true) { OperationRun.create!(FormIntent.run_attributes(payload)) }
        end
        payload["id"]
      rescue ActiveRecord::RecordNotUnique
        payload["id"]
      end

      # Reopens an unconsumed native form after fresh authentication. No input,
      # business write, approval or replacement intent is admitted here.
      def resume_form(context:, resource:, intent_ref:)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        unless FormIntent.uuid?(intent_ref)
          # An unsubmitted form has no row yet; only its own recoverable kind
          # is materialized, then the same checks as a stored intent apply.
          payload = FormIntent.verify(intent_ref)
          raise AccessDenied unless payload && payload["resource_key"] == resource.key.to_s && %w[create update].include?(payload["operation"])
          intent_ref = materialize_form_intent(context: context, reference: intent_ref) || raise(AccessDenied)
        end
        raise AccessDenied unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
        OperationRun.transaction(requires_new: true) do
          run = OperationRun.lock.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          unless run && run.resource_key == resource.key.to_s && %w[create update].include?(run.operation) &&
              run.origin == "ui" && run.status == "proposed" && run.parent_run_id.nil? && run.selection_id.nil? &&
              run.input_digest.nil? && run.confirmed_at.nil? && run.approved_by_ref.nil? && run.approved_digest.nil?
            raise AccessDenied
          end
          raise AccessDenied, "APPROVAL_EXPIRED" unless run.created_at && run.created_at > Time.current - FORM_RECOVERY_WINDOW
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          raise AccessDenied unless !definition.custom? && run.operation_version == operation_version(resource, run.operation)
          ensure_connection!(resource, definition)
          access = Authorization::Access.new(context, resource)
          record = load_record(access, run, definition)
          access.authorize!(run.operation, record)
          if run.operation == "update" && run.expected_version != RecordVersion.of(record)
            raise AccessDenied, "CONFLICT"
          end
          raise AccessDenied unless run.operation != "create" || run.target_id.nil? && run.expected_version.nil?
          definition.fields(access, record)
          run.update!(security_version: context.security_version,
            expires_at: [ Time.current + RailsAiAdmin.configuration.intent_ttl, run.created_at + FORM_RECOVERY_WINDOW ].min)
          FormSession.new(run, record)
        end
      end

      # Computes a safe typed preview without creating an intent or saving domain
      # data. Collection admission and native member preparation share this path.
      def preview(context:, resource:, operation:, target_id: nil, expected_version: nil, input: nil, origin: :ui)
        operation = operation.to_s
        check_origin!(origin)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        access = Authorization::Access.new(context, resource)
        ensure_connection!(resource, definition)
        read_proposal = lambda do
          record = operation == "create" ? access.relation.new : access.find!(target_id, action: operation)
          access.authorize!(operation, record)
          version = operation == "create" ? nil : parse_version(expected_version)
          raise AccessDenied, "CONFLICT" if version && version != RecordVersion.of(record)
          raise ConfigurationError, "Create must not have a target" if operation == "create" && target_id
          raise ConfigurationError, "Custom operations require input-bound preflight" if definition.custom? && input.nil?
          values = input.nil? ? nil : coerce!(access, record, definition, input)
          changes = definition.custom? ? preview_changes(access, record, definition, values) : {}
          [ record, version, values, changes ]
        end
        record, version, values, changes = definition.custom? ? ActiveRecord::Base.while_preventing_writes(&read_proposal) : read_proposal.call
        Preview.new(operation == "create" ? nil : record.id.to_s, version, values || {}, changes)
      rescue Rejection => error
        error.result
      rescue ExecutionContext::DeadlineExceeded
        Result.new(code: "TIMEOUT")
      rescue StandardError => error
        raise if !definition&.custom? || error.is_a?(ConfigurationError) || error.is_a?(AccessDenied)
        Result.new(code: "OPERATION_FAILED")
      end

      # Reauthorizes and consumes a human event atomically with the domain write.
      # human_confirmed comes only from a trusted HTTP/Surface adapter, never from
      # an assistant tool parameter. Origin is audit metadata, not authority.
      def execute(context:, intent_ref:, input:, human_confirmed: false, origin: :ui, binding: nil)
        execute_intent(context: context, intent_ref: intent_ref, input: input, human_confirmed: human_confirmed, origin: origin, binding: binding)
      end

      # Internal worker entry: its authority is the admitted parent and lease,
      # never another synthetic human confirmation. No HTTP adapter calls it.
      def execute_admitted(claim:)
        raise ConfigurationError, "Expected a collection lease claim" unless claim.is_a?(Collections::Claim)
        Collections::Contract.ensure_outside_transaction!
        execute_intent(context: claim.context, intent_ref: claim.operation_run_id,
          input: claim.payload, origin: claim.origin, admission: claim)
      rescue AccessDenied => error
        Result.new(code: error.code)
      end

      def execute_intent(context:, intent_ref:, input:, human_confirmed: false, origin: :ui, binding: nil, admission: nil)
        run = access = definition = nil
        transaction_body_finished = false
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        reject!("NOT_FOUND") unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
        result = OperationRun.transaction(requires_new: true) do
          admission&.lock!(context)
          run = OperationRun.lock.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          reject!("NOT_FOUND") unless run
          reject!("NOT_FOUND") if run.parent_run_id && !admission
          check_origin!(origin)
          reject!("APPROVAL_INVALIDATED") unless run.security_version == context.security_version
          reject!("APPROVAL_EXPIRED") unless run.expires_at && run.expires_at > Time.current
          check_binding!(run, binding) if binding
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          ensure_connection!(resource, definition)
          reject!("NOT_FOUND") if definition.custom? && definition.scope == :collection && !admission
          admission&.validate_child!(run, resource, definition)
          reject!("APPROVAL_INVALIDATED") unless run.operation_version == operation_version(resource, run.operation)
          access = Authorization::Access.new(context, resource)
          record = load_record(access, run, definition)
          if definition.custom? && run.status == "succeeded"
            access.authorize_receipt!(run.operation, record)
          else
            access.authorize!(run.operation, record)
          end
          values = coerce!(access, record, definition, input, replay: run.status == "succeeded")
          if run.operation == "create"
            record.assign_attributes(column_attributes(resource, values))
            access.authorize!(:create, record)
            writable = access.fields(:write, record, operation: :create).map { |field| field.name.to_s }
            reject!("NOT_FOUND") unless (values.keys - writable).empty?
          end
          digest = InputSchema.digest(values)
          if run.input_digest && run.input_digest != digest
            reject!(run.status == "succeeded" ? "IDEMPOTENCY_CONFLICT" : "APPROVAL_INVALIDATED")
          end
          if run.status == "succeeded"
            if run.operation == "create"
              record = access.relation.find_by(resource.model_class.primary_key => run.record_id)
              reject!("NOT_FOUND") unless record
            end
            next projection(access, run, record, replayed: true)
          end
          reject!("CONFLICT") unless run.status == "proposed"
          reject!("APPROVAL_REQUIRED") unless admission || human_confirmed == true
          if run.operation != "create" && RecordVersion.of(record) != run.expected_version
            reject!("CONFLICT")
          end
          # A write claim, not a process mutex, serializes SQLite writers too.
          run.update!(status: "running", input_digest: digest)
          if definition.custom?
            before = record.attributes_before_type_cast.deep_dup
            context_for_handler = ExecutionContext.new(context, resource, record, run: run, duration: definition.handler_class.max_duration)
            outcome = call_handler(definition, context_for_handler, record, values)
            unless outcome.is_a?(Operation::Outcome)
              raise ConfigurationError, "Operation must return success, invalid or conflict"
            end
            raise ConfigurationError, "Unknown operation outcome" unless %w[OK VALIDATION_FAILED CONFLICT].include?(outcome.code)
            if outcome.code != "OK"
              names = outcome.fields & definition.fields(access, record).map { |field| field.name.to_s }
              reject!(outcome.code, errors: names.any? ? names.to_h { |name| [ name, [ Field.error_message(:invalid, "is invalid") ] ] } : { "base" => [ Field.error_message(:operation_rejected, "operation was rejected") ] })
            end
            unless record.persisted? && !record.destroyed? && !record.has_changes_to_save? && outcome.record_id == run.target_id
              reject!("VALIDATION_FAILED", errors: { "base" => [ "operation did not persist its target" ] })
            end
            record.reload
            if before != record.attributes_before_type_cast && RecordVersion.of(record) == run.expected_version
              raise ConfigurationError, "Custom writes must advance the target lock_version or updated_at"
            end
            changed_fields = resource.fields.select { |field| before[field.column] != record.attributes_before_type_cast[field.column] }.map { |field| field.name.to_s }
            WorkItem.where(operation_run_id: run.id).update_all(expected_version: RecordVersion.of(record))
          else
            lists = resource.fields.select { |field| field.scalar_type == :references && values.key?(field.name.to_s) }
            before_lists = lists.to_h { |field| [ field.name.to_s, stored_references(record, field) ] }
            record.assign_attributes(column_attributes(resource, unchanged_precision(resource, record, values))) if run.operation == "update"
            names = field_names_by_column(resource)
            changed_fields = record.changes.keys.map { |column| names.fetch(column, column) } & values.keys
            # A password writer changes a digest column the resource never names.
            changed_fields |= resource.fields.select { |field| field.scalar_type == :password && !values[field.name.to_s].nil? }.map { |field| field.name.to_s }
            # Action Text keeps the content in its own record.
            changed_fields |= resource.fields.select { |field| field.scalar_type == :rich_text && values.key?(field.name.to_s) && record.public_send(field.column)&.changed? }.map { |field| field.name.to_s }
            # Active Storage keeps attachment changes outside the attributes.
            if record.respond_to?(:attachment_changes)
              changed_fields |= resource.fields.select { |field| field.scalar_type == :file && values.key?(field.name.to_s) && record.attachment_changes.key?(field.column) }.map { |field| field.name.to_s }
            end
            changed_files = apply_files(access, record, values)
            changed_fields |= changed_files
            # Join rows change no owner column, so a changed list touches the
            # record: its version advances and a concurrent form conflicts.
            changed_lists = lists.map { |field| field.name.to_s }.reject { |name| before_lists.fetch(name) == values.fetch(name) }
            changed_fields |= changed_lists
            persisted = if run.operation == "destroy" && resource.soft_delete?
              soft_delete(resource, record)
            else
              definition.handler_class.new.perform(nil, record, values)
            end
            reject!("VALIDATION_FAILED", errors: { "base" => [ "could not be saved" ] }) unless persisted
            record.touch if run.operation == "update" && (changed_lists.any? || changed_files.any?)
          end
          unless run.operation == "destroy" || access.relation.where(resource.model_class.primary_key => record.id).exists?
            reject!("NOT_FOUND")
          end
          audit = AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
            resource_key: run.resource_key, operation: run.operation, status: "succeeded", code: "OK",
            record_id: record.id.to_s, correlation_ref: run.id, origin: origin.to_s,
            changed_fields: changed_fields, created_at: Time.current)
          attributes = { status: "succeeded", record_id: record.id.to_s, audit_event_id: audit.id, completed_at: Time.current }
          attributes.merge!(approved_by_ref: context.actor_ref, approved_digest: digest, confirmed_at: Time.current) unless admission
          run.update!(attributes)
          receipt = projection(access, run, record)
          admission&.complete!(run)
          transaction_body_finished = true
          receipt
        end
        result || committed_callback_result(context, run, transaction_body_finished) || reject!("VALIDATION_FAILED", errors: { "base" => [ "transaction was rolled back" ] })
      rescue StandardError => error
        committed = committed_callback_result(context, run, transaction_body_finished)
        return committed if committed
        case error
        when Rejection
          audit_failure(context, run, error.result.code, origin) unless admission
          error.result
        when AccessDenied
          audit_failure(context, run, error.code, origin) unless admission
          Result.new(code: error.code)
        when ActiveRecord::RecordInvalid
          allowed = if definition&.custom?
            access&.operation_fields(run.operation, error.record)&.map { |field| field.name.to_s } || []
          else
            access&.fields(:write, error.record, operation: run.operation)&.map { |field| field.name.to_s } || []
          end
          names = definition&.custom? || !access ? {} : field_names_by_column(access.resource)
          errors = validation_errors(error.record.errors, names, allowed)
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: errors.presence || { "base" => [ Field.error_message(:invalid, "is invalid") ] })
        when ActiveRecord::RecordNotDestroyed
          if run&.operation == "destroy" && !definition&.custom?
            # dependent: :restrict_with_error (or a before_destroy abort) says
            # why; it is a lasting state, not a stale form (RAA-012).
            audit_failure(context, run, "RESTRICTED", origin) unless admission
            Result.new(code: "RESTRICTED", errors: { "base" => restriction_messages(error.record) })
          else
            audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
            Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "operation was not saved" ] })
          end
        when ActiveRecord::RecordNotSaved
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "operation was not saved" ] })
        when ActiveRecord::InvalidForeignKey
          # On delete, a foreign key means other rows still reference the
          # record; elsewhere a referenced target vanished after admission.
          if run&.operation == "destroy" && !definition&.custom?
            audit_failure(context, run, "RESTRICTED", origin) unless admission
            Result.new(code: "RESTRICTED", errors: { "base" => [ RESTRICTED_MESSAGE ] })
          else
            Result.new(code: "CONFLICT")
          end
        when ActiveRecord::RangeError
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "value is out of range" ] })
        when ExecutionContext::DeadlineExceeded
          audit_failure(context, run, "TIMEOUT", origin) unless admission
          Result.new(code: "TIMEOUT")
        when ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
          # A references target deleted after its check fails the id writer.
          ActiveRecord::RecordNotFound
          Result.new(code: "CONFLICT")
        when ActiveRecord::StatementInvalid
          if defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
            Result.new(code: "CONFLICT")
          elsif definition&.custom?
            audit_failure(context, run, "OPERATION_FAILED", origin) unless admission
            Result.new(code: "OPERATION_FAILED")
          else
            raise
          end
        else
          if definition&.custom? && !error.is_a?(ConfigurationError)
            audit_failure(context, run, "OPERATION_FAILED", origin) unless admission
            Result.new(code: "OPERATION_FAILED")
          else
            raise
          end
        end
      end

      private :execute_intent

      private

      class Rejection < StandardError # :nodoc:
        attr_reader :result
        def initialize(result)
          @result = result
          super(result.code)
        end
      end

      # The host model's own messages for fields this actor may write, and its
      # base messages (RAA-011). config.validation_messages = :generic keeps
      # the earlier "is invalid" for every field instead.
      def validation_errors(model_errors, names, allowed)
        generic = RailsAiAdmin.configuration.validation_messages == :generic
        errors = model_errors.attribute_names.each_with_object({}) do |attribute, result|
          next if attribute == :base
          name = names.fetch(attribute.to_s, attribute.to_s)
          next unless allowed.include?(name)
          result[name] = generic ? [ Field.error_message(:invalid, "is invalid") ] : bounded_messages(model_errors.messages_for(attribute))
        end
        base = generic ? [] : bounded_messages(model_errors.messages_for(:base), fallback: false)
        errors["base"] = base if base.any?
        errors
      end

      def bounded_messages(messages, fallback: true)
        kept = Array(messages).select { |message| message.is_a?(String) && message.valid_encoding? }
          .map { |message| message.gsub(/[[:cntrl:]]/, " ").squish.truncate(200) }.reject(&:empty?).uniq.first(3)
        kept.empty? && fallback ? [ Field.error_message(:invalid, "is invalid") ] : kept
      end

      RESTRICTED_MESSAGE = "This record is still referenced by other records and cannot be deleted."

      # Host base messages from restrict_with_error are model-authored text
      # about the record itself; keep at most three, bounded and plain.
      def restriction_messages(record)
        messages = Array(record&.errors&.[](:base)).select { |message| message.is_a?(String) && message.valid_encoding? }
          .map { |message| message.gsub(/[[:cntrl:]]/, " ").squish.truncate(200) }.reject(&:empty?).first(3)
        messages.presence || [ RESTRICTED_MESSAGE ]
      end

      def reject!(code, errors: {})
        raise Rejection, Result.new(code: code, errors: errors)
      end

      def check_origin!(origin)
        raise ConfigurationError, "Unsupported origin" unless ORIGINS.include?(origin.to_s)
      end

      def check_binding!(run, binding)
        expected = { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id }
        reject!("NOT_FOUND") unless binding.transform_values { |value| value&.to_s } == expected
      end

      def parse_version(value)
        raise AccessDenied, "CONFLICT" unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
        value.is_a?(String) ? Integer(value, 10) : value
      end

      def ensure_connection!(resource, definition)
        model = resource.model_class
        unless model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool) && model.connection_pool.equal?(WorkItem.connection_pool) && model.connection_pool.equal?(BatchItem.connection_pool)
          raise ConfigurationError, "Domain, intent and audit must use the same connection pool"
        end
        unless RecordVersion.supported?(model)
          raise ConfigurationError, "Writes require lock_version or an updated_at timestamp, and a single primary key"
        end
        version_column = RecordVersion.column(model)
        if resource.fields.any? { |field| field.column == version_column && (field.writable?(:create) || field.writable?(:update)) }
          raise ConfigurationError, "#{version_column} carries the record version and cannot be a writable field"
        end
        unless %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Only SQLite and PostgreSQL are supported for writes"
        end
        if definition.custom?
          definition.handler_class.atomic_models.each do |name|
            related = name.constantize
            unless related.is_a?(Class) && related < ActiveRecord::Base && related.connection_pool.equal?(model.connection_pool)
              raise ConfigurationError, "Every declared atomic model must use the operation connection pool"
            end
          end
        end
      end

      def operation_version(resource, operation)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        RunnerFingerprint.call(resource, definition)
      end

      def load_record(access, run, definition)
        if run.status == "succeeded" && run.operation == "destroy"
          # Deleted records have no current projection. Require a fresh
          # collection-level destroy decision before returning even a receipt.
          nil
        elsif run.operation == "create"
          access.relation.new
        elsif definition.custom? && run.status == "succeeded"
          access.relation.lock.find_by(access.resource.model_class.primary_key => run.record_id).tap { |record| reject!("NOT_FOUND") unless record }
        else
          access.find!(run.target_id, action: run.operation, lock: true)
        end
      end

      def coerce!(access, record, definition, input, replay: false)
        fields = replay && definition.custom? ? definition.handler_class.input : definition.fields(access, record)
        result = InputSchema.new(fields, partial: definition.key == "update" && !definition.custom?).coerce(input, time_zone: access.context.time_zone)
        reject!(replay ? "IDEMPOTENCY_CONFLICT" : "VALIDATION_FAILED", errors: replay ? {} : result.errors) unless result.valid?
        check_references!(access, record, fields, result.values) unless replay
        retain_hidden_references(access, record, fields, result.values)
      end

      def stored_references(record, field)
        return [] unless record&.persisted?
        record.public_send(field.column).map(&:to_s).uniq.sort
      end

      # A list keeps the stored targets this actor cannot see: a person can
      # neither remove nor learn about records hidden by the target's policy.
      def retain_hidden_references(access, record, fields, values)
        lists = fields.select { |field| field.scalar_type == :references && values.key?(field.name.to_s) }
        return values if lists.empty?
        resolver = Fields::Association.new(access.context, access.resource)
        merged = values.dup
        lists.each do |field|
          stored = stored_references(record, field)
          if stored.size > Field::MAX_REFERENCES
            reject!("VALIDATION_FAILED", errors: { field.name.to_s => [ Field.error_message(:too_many, "can name at most %{count} records", count: Field::MAX_REFERENCES) ] })
          end
          resolver.prime(field, stored)
          hidden = stored.reject { |id| resolver.admissible?(field, id) }
          merged[field.name.to_s] = (values.fetch(field.name.to_s) | hidden).sort.freeze
        end
        merged.freeze
      end

      # A changed reference must name a target this actor can currently see in
      # the target resource. Keeping the stored key is not a new attachment, so
      # an edit never forces clearing a reference the actor cannot see.
      def check_references!(access, record, fields, values)
        references = fields.select { |field| Field::REFERENCE_TYPES.include?(field.scalar_type) && !values[field.name.to_s].nil? }
        return if references.empty?
        resolver = Fields::Association.new(access.context, access.resource)
        errors = references.each_with_object({}) do |field, result|
          value = values.fetch(field.name.to_s)
          if field.scalar_type == :references
            # Only newly added targets need to be visible now.
            added = value - stored_references(record, field)
            resolver.prime(field, added)
            result[field.name.to_s] = [ Field.error_message(:unavailable_choice, Fields::Association::UNAVAILABLE) ] unless added.all? { |id| resolver.admissible?(field, id) }
            next
          end
          stored = record&.persisted? && record.has_attribute?(field.column) ? record.read_attribute(field.column) : nil
          next if !stored.nil? && stored.to_s == value
          result[field.name.to_s] = [ Field.error_message(:unavailable_choice, Fields::Association::UNAVAILABLE) ] unless resolver.admissible?(field, value)
        end
        reject!("VALIDATION_FAILED", errors: errors) if errors.any?
      end

      # A form shows a timestamp to the second. Submitting it back unchanged
      # must not drop the stored fraction (RAA-002/RAA-015), so a whole-second
      # value equal to the stored one truncated keeps the stored one.
      def unchanged_precision(resource, record, values)
        fields = resource.fields.index_by { |field| field.name.to_s }
        values.to_h do |name, value|
          field = fields[name]
          stored = field && field.scalar_type == :datetime && record.has_attribute?(field.column) ? record.read_attribute(field.column) : nil
          kept = stored.respond_to?(:usec) && value.respond_to?(:usec) && value.usec.zero? && stored.usec.nonzero? && stored.change(usec: 0) == value
          [ name, kept ? stored : value ]
        end
      end

      # files changes are applied by apply_files, never assigned as a list.
      def column_attributes(resource, values)
        columns = resource.fields.to_h { |field| [ field.name.to_s, field.column ] }
        lists = resource.fields.select { |field| field.scalar_type == :files }.map { |field| field.name.to_s }
        values.except(*lists).transform_keys { |name| columns.fetch(name, name) }
      end

      # Removes the named attachments of this record and attaches the new
      # blobs. Returns the names of files fields that changed.
      def apply_files(access, record, values)
        access.resource.fields.select { |field| field.scalar_type == :files && values.key?(field.name.to_s) }.filter_map do |field|
          change = values.fetch(field.name.to_s) || { "add" => [], "remove" => [] }
          attached = record.public_send(field.column)
          stored = record.persisted? ? access.stored_attachments(record, field) : nil
          removed = stored ? stored.where(id: change["remove"]).to_a : []
          unless removed.size == change["remove"].size
            reject!("VALIDATION_FAILED", errors: { field.name.to_s => [ Field.error_message(:unavailable_choice, Fields::Association::UNAVAILABLE) ] })
          end
          total = (stored ? stored.count : 0) - removed.size + change["add"].size
          if total > field.options[:max_files]
            reject!("VALIDATION_FAILED", errors: { field.name.to_s => [ Field.error_message(:too_many_files, "can hold at most %{count} files", count: field.options[:max_files]) ] })
          end
          # The attachment rows go with this transaction; their blobs are
          # purged only after it commits, so a rollback loses no file.
          blobs = removed.map(&:blob)
          removed.each(&:delete)
          ActiveRecord.after_all_transactions_commit { blobs.each { |blob| blob.purge_later unless blob.attachments.exists? } } if blobs.any?
          attached.attach(*change["add"]) if change["add"].any?
          field.name.to_s if removed.any? || change["add"].any?
        end
      end

      def field_names_by_column(resource) = resource.fields.to_h { |field| [ field.column, field.name.to_s ] }

      def preview_changes(access, record, definition, values)
        handler_context = ExecutionContext.new(access.context, access.resource, record, duration: definition.handler_class.max_duration)
        changes = ActiveRecord::Base.while_preventing_writes { definition.handler_class.new.preflight(handler_context, record, values) }
        handler_context.check_deadline!
        if changes.is_a?(Operation::Outcome) && %w[VALIDATION_FAILED CONFLICT].include?(changes.code)
          names = changes.fields & definition.fields(access, record).map { |field| field.name.to_s }
          reject!(changes.code, errors: names.any? ? names.to_h { |name| [ name, [ Field.error_message(:invalid, "is invalid") ] ] } : { "base" => [ Field.error_message(:operation_rejected, "operation was rejected") ] })
        end
        raise ConfigurationError, "Preflight must return a field-value hash without mutating its target" unless changes.is_a?(Hash) && !record.has_changes_to_save?
        readable = access.fields(:read, record, view: :show)
        original = begin
          access.project(record, view: :show)
        rescue AccessDenied
          {}
        end
        readable.filter_map do |field|
          name = field.name.to_s
          next if field.virtual?
          next unless original.key?(name) && (changes.key?(name) || changes.key?(field.name))
          value = changes.key?(name) ? changes[name] : changes[field.name]
          value = field.coerce_output(value, time_zone: access.context.time_zone)
          [ name, { "before" => original[name], "after" => value } ]
        end.to_h
      rescue ArgumentError, ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Preflight violated its pure typed preview contract", cause: nil
      end

      # Sets the timestamp with callbacks and the record version, but without
      # validations: a record that no longer validates can still be deleted.
      def soft_delete(resource, record)
        record.public_send("#{resource.soft_delete}=", Time.current)
        record.save!(validate: false)
      end

      def call_handler(definition, context, record, values)
        nested_savepoint = false
        connection = OperationRun.connection
        listener = ->(_event, _start, _finish, _id, payload) { nested_savepoint = true if payload[:connection].equal?(connection) && payload[:sql].match?(/\A(?:SAVEPOINT|RELEASE SAVEPOINT|ROLLBACK TO SAVEPOINT)\b/i) }
        context.check_deadline!
        outcome = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { definition.handler_class.new.perform(context, record, values) }
        raise ConfigurationError, "Custom handlers must not open requires_new transactions" if nested_savepoint
        context.check_deadline!
        outcome
      end

      def projection(access, run, record, replayed: false)
        values = if run.operation == "destroy"
          {}
        else
          begin
            access.project(record)
          rescue AccessDenied
            {}
          end
        end
        Result.new(code: "OK", record_id: run.record_id, audit_ref: run.audit_event_id, values: values, replayed: replayed,
          warning: run.warning_code, work_refs: WorkItem.where(operation_run_id: run.id).pluck(:id))
      end

      def committed_callback_result(context, run, body_finished)
        return unless body_finished && run && !OperationRun.connection.transaction_open?
        committed = OperationRun.uncached do
          OperationRun.find_by(id: run.id, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, status: "succeeded")
        end
        return unless committed
        committed.update!(warning_code: "POST_COMMIT_CALLBACK_FAILED")
        # after_commit exceptions cannot turn an already committed business write
        # into a failure. Keep its receipt, without running callbacks or exposing
        # record content again. External-effect reconciliation belongs to host.
        Result.new(code: "OK", record_id: committed.record_id, audit_ref: committed.audit_event_id,
          warning: "POST_COMMIT_CALLBACK_FAILED", work_refs: WorkItem.where(operation_run_id: committed.id).pluck(:id))
      end

      def audit_failure(context, run, code, origin)
        return unless run && run.actor_ref == context.actor_ref && run.tenant_ref == context.tenant_ref
        return if run.parent_run_id || run.selection_id
        AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          resource_key: run.resource_key, operation: run.operation, status: "rejected", code: code,
          record_id: run.target_id, correlation_ref: run.id, origin: origin.to_s, changed_fields: [], created_at: Time.current)
      end
    end
  end
end
