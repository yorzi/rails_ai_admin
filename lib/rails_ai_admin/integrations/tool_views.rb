# frozen_string_literal: true

require "json"

module RailsAiAdmin
  module Integrations
    # Admin review Surfaces on the host-owned rails_tool_views runtime.
    #
    # Required only when `config.surfaces` is enabled, so conventional boot never
    # loads rails_tool_views. The admin reads none of the host's global
    # rails_tool_views settings (resolver, parent controller, adapter,
    # auto_deliver) and changes none of them. Admin endpoints pass an explicit
    # `raa:` Scope and bind the current admin Context for the duration of one
    # call; policy and handler deny when no matching Context is bound, so another
    # route (such as the host's product engine mount) can never act on them.
    module ToolViews
      KEY = "raa_operation_review"
      RECORD_CARD_KEY = "raa_record_card"
      RECORD_TABLE_KEY = "raa_record_table"
      METRIC_CARD_KEY = "raa_metric_card"
      TASK_PROGRESS_KEY = "raa_task_progress"
      EXECUTION_RECEIPT_KEY = "raa_execution_receipt"
      EDITABLE_FORM_KEY = "raa_editable_form"
      VERSION = "1"
      PARTIAL = "rails_ai_admin/surfaces/operation_review"
      RECORD_CARD_PARTIAL = "rails_ai_admin/surfaces/record_card"
      RECORD_TABLE_PARTIAL = "rails_ai_admin/surfaces/record_table"
      METRIC_CARD_PARTIAL = "rails_ai_admin/surfaces/metric_card"
      TASK_PROGRESS_PARTIAL = "rails_ai_admin/surfaces/task_progress"
      EXECUTION_RECEIPT_PARTIAL = "rails_ai_admin/surfaces/execution_receipt"
      EDITABLE_FORM_PARTIAL = "rails_ai_admin/surfaces/editable_form"
      CONTEXT_KEY = :rails_ai_admin_surface_context
      UUID = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
      RESOURCE_KEY_PATTERN = "^[a-z][a-z0-9_]{0,63}$"
      MAX_INPUT_BYTES = 16_384
      MAX_TABLE_COLUMNS = 6
      # Props hold only a server intent reference and its canonical wire input,
      # so the component digest never depends on reloadable host code.
      SCHEMA = {
        type: "object", additionalProperties: false, required: %w[intent input],
        properties: { intent: { type: "string", pattern: UUID, maxLength: 36 }, input: { type: "string", maxLength: MAX_INPUT_BYTES } }
      }.freeze
      RECORD_CARD_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[resource record_id],
        properties: {
          resource: { type: "string", pattern: RESOURCE_KEY_PATTERN },
          record_id: { type: "string", minLength: 1, maxLength: 100 }
        }
      }.freeze
      RECORD_TABLE_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[resource ids],
        properties: {
          resource: { type: "string", pattern: RESOURCE_KEY_PATTERN },
          ids: { type: "array", maxItems: 20, items: { type: "string", minLength: 1, maxLength: 100 } },
          scope: { type: %w[string null], maxLength: 100 },
          query: { type: %w[string null], maxLength: 200 },
          sort: { type: %w[string null], maxLength: 100 },
          direction: { type: %w[string null], enum: [ "asc", "desc", nil ] },
          omitted: { type: "integer", minimum: 0 }
        }
      }.freeze
      METRIC_CARD_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[resource function],
        properties: {
          resource: { type: "string", pattern: RESOURCE_KEY_PATTERN },
          function: { type: "string", enum: %w[count sum average minimum maximum] },
          field: { type: %w[string null], maxLength: 100 },
          group_by: { type: %w[string null], maxLength: 100 },
          period: { type: %w[string null], enum: [ "day", "week", "month", "year", nil ] },
          scope: { type: %w[string null], maxLength: 100 },
          query: { type: %w[string null], maxLength: 200 },
          filters_json: { type: %w[string null], maxLength: 4096 },
          any_json: { type: %w[string null], maxLength: 4096 },
          relation_filters_json: { type: %w[string null], maxLength: 4096 },
          computed_at: { type: %w[string null], maxLength: 64 }
        }
      }.freeze
      TASK_PROGRESS_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[task_id],
        properties: { task_id: { type: "string", pattern: UUID, maxLength: 36 } }
      }.freeze
      EXECUTION_RECEIPT_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[run_id],
        properties: { run_id: { type: "string", pattern: UUID, maxLength: 36 } }
      }.freeze
      EDITABLE_CONFIRM_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[confirmed_intent],
        properties: { confirmed_intent: { type: "string", pattern: UUID, maxLength: 36 } }
      }.freeze
      UPDATE_PREVIEW_SCHEMA = {
        type: "object", additionalProperties: false, required: %w[entries],
        properties: {
          entries: {
            type: "array", minItems: 1, maxItems: 64,
            items: {
              type: "object", additionalProperties: false, required: %w[name value],
              properties: {
                name: { type: "string", pattern: "^[a-z][a-z0-9_]{0,63}$", maxLength: 64 },
                value: { type: "string", maxLength: 4096 }
              }
            }
          }
        }
      }.freeze
      READ_COMPONENTS = {
        RECORD_CARD_KEY => { description: "Admin record summary card", schema: RECORD_CARD_SCHEMA, partial: RECORD_CARD_PARTIAL }.freeze,
        RECORD_TABLE_KEY => { description: "Admin bounded record table", schema: RECORD_TABLE_SCHEMA, partial: RECORD_TABLE_PARTIAL }.freeze,
        METRIC_CARD_KEY => { description: "Admin aggregate metric card", schema: METRIC_CARD_SCHEMA, partial: METRIC_CARD_PARTIAL }.freeze,
        EXECUTION_RECEIPT_KEY => { description: "Admin committed execution receipt", schema: EXECUTION_RECEIPT_SCHEMA, partial: EXECUTION_RECEIPT_PARTIAL }.freeze
      }.freeze
      ALL_KEYS = [ KEY, *READ_COMPONENTS.keys, TASK_PROGRESS_KEY, EDITABLE_FORM_KEY ].freeze
      CONFIRM_SCHEMA = { type: "object", additionalProperties: false, properties: {} }.freeze
      # Business outcomes are recorded on the Surface with their failure audit.
      TERMINAL = {
        "CONFLICT" => "The record changed or was busy. Start a new review from the record.",
        "APPROVAL_EXPIRED" => "This review expired. Start a new review from the record.",
        "APPROVAL_INVALIDATED" => "Access or the operation changed. Start a new review from the record.",
        "APPROVAL_REQUIRED" => "This operation needs a new review.",
        "SELF_APPROVAL_FORBIDDEN" => "This operation requires approval from another authorized reviewer.",
        "VALIDATION_FAILED" => "The operation rejected this input. Start a new review from the record.",
        "IDEMPOTENCY_CONFLICT" => "This review no longer matches the recorded operation."
      }.freeze
      Review = ::Data.define(:run, :resource, :definition, :access, :record)
      RecordCardData = ::Data.define(:resource, :record, :label, :fields)
      RecordTableData = ::Data.define(:resource, :columns, :rows, :omitted, :scope, :query, :sort, :direction)
      MetricCardData = ::Data.define(:resource, :aggregate, :value_text, :groups, :scope, :query, :filters_summary, :time_zone, :computed_at)
      TaskProgressData = ::Data.define(:task, :effective_status, :succeeded_count, :failed_count, :total_count, :can_cancel)
      ExecutionReceiptData = ::Data.define(:run, :resource, :operation_label, :record_label, :changed_fields, :verification_status, :verification_checks, :work_statuses, :audit_event_id, :task_id, :can_undo)
      ASSISTANT_ADAPTER = "raa_assistant"

      class << self
        def available?
          defined?(::RailsToolViews::Registry) ? true : false
        end

        # Read-only check used by diagnostics so doctor never mutates the
        # host-owned rails_tool_views registry.
        def check_registration!
          raise ConfigurationError, "rails_tool_views is not loaded" unless available?
          verify_if_present(KEY) { |component| verify_component!(component) }
          READ_COMPONENTS.each_key do |key|
            verify_if_present(key) { |component| verify_read_component!(key, component) }
          end
          verify_if_present(TASK_PROGRESS_KEY) { |component| verify_task_progress_component!(component) }
          verify_if_present(EDITABLE_FORM_KEY) { |component| verify_editable_form_component!(component) }
        end

        # Re-registers after a host `reset_registry!`. The contract is constant,
        # so an existing registration must be exactly this one.
        def ensure_registered!
          raise ConfigurationError, "rails_tool_views is not loaded" unless available?
          review = ensure_component(KEY) { register }
          verify_component!(review)
          READ_COMPONENTS.each do |key, spec|
            component = ensure_component(key) { register_read_component(key, spec) }
            verify_read_component!(key, component)
          end
          progress = ensure_component(TASK_PROGRESS_KEY) { register_task_progress }
          verify_task_progress_component!(progress)
          editable = ensure_component(EDITABLE_FORM_KEY) { register_editable_form }
          verify_editable_form_component!(editable)
          review
        end

        def verify_component!(component)
          unless component.policy.equal?(POLICY) && component.actions.fetch("confirm").handler.equal?(CONFIRM) &&
              component.actions["dismiss"]&.handler.equal?(DISMISS)
            raise ConfigurationError, "#{KEY} is registered by other code"
          end
          component
        end

        def verify_read_component!(key, component)
          unless component.policy.equal?(READ_POLICY) && component.actions.empty?
            raise ConfigurationError, "#{key} is registered by other code"
          end
          component
        end

        def verify_task_progress_component!(component)
          unless component.policy.equal?(TASK_PROGRESS_POLICY) &&
              component.actions["cancel"]&.handler.equal?(CANCEL_TASK)
            raise ConfigurationError, "#{TASK_PROGRESS_KEY} is registered by other code"
          end
          component
        end

        def verify_editable_form_component!(component)
          unless component.policy.equal?(EDITABLE_FORM_POLICY) &&
              component.actions["update_preview"]&.handler.equal?(UPDATE_EDITABLE_PREVIEW) &&
              component.actions["confirm"]&.handler.equal?(CONFIRM_EDITABLE_FORM) &&
              component.actions["dismiss"]&.handler.equal?(DISMISS_EDITABLE_FORM)
            raise ConfigurationError, "#{EDITABLE_FORM_KEY} is registered by other code"
          end
          component
        end

        def scope_for(context)
          raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
          ::RailsToolViews::Scope.new(actor: context.actor_ref, tenant: context.tenant_ref)
        end

        # Binds the current admin Context for one admin endpoint call.
        def with_context(context)
          raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
          state = ActiveSupport::IsolatedExecutionState
          previous = state[CONTEXT_KEY]
          state[CONTEXT_KEY] = context
          yield
        ensure
          state[CONTEXT_KEY] = previous if state
        end

        def current_context = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]

        # Presents (or replays) the review Surface for an unconsumed intent. A
        # native intent replays per intent; an assistant intent belongs to its
        # chat and replays per persisted tool call.
        def present(context:, resource:, definition:, record:, intent_ref:, input:, chat: nil, call_id: nil, assistant_call: nil)
          ensure_registered!
          if definition.custom?
            raise AccessDenied unless resource.surface_operation?(definition.key) && definition.scope == :member
          else
            # A native create, update or delete is reviewed here only when the
            # assistant proposed it and the resource allows that change.
            raise AccessDenied unless (chat || assistant_call) && resource.assistant_change?(definition.key)
          end
          raise AccessDenied if chat && assistant_call
          origin = chat || assistant_call ? "assistant" : "ui"
          raise AccessDenied if assistant_call && definition.custom? && !resource.assistant_operation?(definition.key)
          raise AccessDenied unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
          raise AccessDenied if chat && !(call_id.is_a?(String) && chat.current_for?(context) && chat.actor_ref == context.actor_ref && chat.tenant_ref == context.tenant_ref)
          run = OperationRun.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          unless run && run.id == intent_ref && run.resource_key == resource.key.to_s && run.operation == definition.key.to_s &&
              run.target_id == record.id&.to_s && run.status == "proposed" && run.origin == origin && run.parent_run_id.nil?
            raise AccessDenied
          end
          raise AccessDenied, "APPROVAL_EXPIRED" unless run.expires_at && run.expires_at > Time.current
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.security_version == context.security_version
          wire = canonical_input(input)
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.input_digest && run.input_digest == InputSchema.digest(input_values(context, resource, definition, record, wire))
          reference, correlation = if chat
            [ chat.context_reference, { adapter: ASSISTANT_ADAPTER, call_id: call_id, context: chat.context_reference } ]
          elsif assistant_call
            [ assistant_call.fetch(:conversation), { adapter: "raa_assistant", call_id: assistant_call.fetch(:call_id), context: assistant_call.fetch(:conversation) } ]
          else
            [ "raa:intent:#{run.id}", { adapter: "raa_native_review", call_id: run.id, context: "raa:intent:#{run.id}" } ]
          end
          with_context(context) do
            ::RailsToolViews.present(KEY, props: { "intent" => run.id, "input" => wire }, scope: scope_for(context),
              context: reference, correlation: correlation)
          end
        end

        # The Surface an earlier attempt presented for this persisted tool call,
        # so a retried tool does not prepare a second intent. Byte-exact match.
        def assistant_surface(context, chat, call_id)
          lookup = { adapter: ASSISTANT_ADAPTER, call_id: call_id, context_ref: chat.context_reference,
            actor_ref: context.actor_ref, tenant_ref: context.tenant_ref }
          prior = ::RailsToolViews::Presentation.find_by(lookup)
          return unless prior && lookup.all? { |attribute, value| prior.public_send(attribute) == value }
          with_context(context) { ::RailsToolViews.restore(prior.surface_id, scope: scope_for(context)) }
        rescue ::RailsToolViews::Error
          nil
        end

        # Canonical wire strings for typed operation values, as native forms send.
        def wire_input(values)
          values.to_h do |name, value|
            wire = case value
            when BigDecimal then value.to_s("F")
            when Time, ActiveSupport::TimeWithZone then value.to_time.getutc.iso8601(6)
            when Date then value.iso8601
            else value
            end
            [ name.to_s, wire ]
          end
        end

        # Current authorized review for props, or nil. Never trusts the Surface.
        def review(context, props)
          return unless context.is_a?(Context) && props.is_a?(Hash) && props["intent"].is_a?(String)
          run = OperationRun.find_by(id: props["intent"], tenant_ref: context.tenant_ref)
          return unless run && run.id == props["intent"] && run.parent_run_id.nil? && run.selection_id.nil?
          proposer = OperationRun.column_names.include?("proposed_by_actor_ref") ? run.proposed_by_actor_ref : nil
          return unless run.actor_ref == context.actor_ref || (proposer.present? && proposer == context.actor_ref)
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          if definition.custom?
            return unless definition.scope == :member && resource.surface_operation?(definition.key)
          else
            return unless run.origin == "assistant" && resource.assistant_change?(definition.key)
          end
          access = Authorization::Access.new(context, resource)
          Review.new(run, resource, definition, access, review_record(access, run))
        rescue AccessDenied, ConfigurationError, ActiveRecord::RecordNotFound
          nil
        end

        def authorize(access)
          context = current_context
          return false unless context.is_a?(Context) && access.actor == context.actor_ref && access.tenant == context.tenant_ref
          review = review(context, access.props)
          return false unless review
          case access.operation
          when :present then review.run.status == "proposed"
          # A completed review is a receipt: like native replay it needs the
          # independent receipt grant, not the (possibly lapsed) command grant.
          when :read then review.run.status != "succeeded" || receipt?(review)
          when :action then %w[confirm dismiss].include?(access.action)
          else false
          end
        end

        # Read-only interactive tool views: deny every action, require live
        # assistant? + resource/record/aggregate grants on both present and read.
        def authorize_read(access)
          context = current_context
          return false unless context.is_a?(Context) && access.actor == context.actor_ref && access.tenant == context.tenant_ref
          return false unless %i[present read].include?(access.operation)
          props = access.props
          return false unless props.is_a?(Hash)
          if props.key?("run_id")
            return execution_receipt_authorized?(context, props["run_id"])
          end
          return false unless props["resource"].is_a?(String)
          resource = RailsAiAdmin.registry.fetch(props["resource"])
          auth = Authorization::Access.new(context, resource)
          auth.authorize_assistant!
          if props.key?("record_id")
            return false unless props["record_id"].is_a?(String) && auth.canonical_id?(props["record_id"])
            auth.find!(props["record_id"])
            true
          elsif props.key?("ids")
            auth.authorize!(:index)
            true
          elsif props.key?("function")
            auth.authorize!(:index)
            if props["field"].present?
              field = auth.fields(:read).find { |candidate| candidate.name.to_s == props["field"] && !candidate.virtual? }
              return false unless field&.aggregate_functions&.include?(props["function"].to_sym)
            end
            if props["group_by"].present?
              allowed_types = props["period"].present? ? Field::PERIOD_TYPES : Field::GROUP_TYPES
              group = auth.fields(:filter).find { |candidate| candidate.name.to_s == props["group_by"] }
              return false unless group && allowed_types.include?(group.scalar_type)
            end
            true
          else
            false
          end
        rescue AccessDenied, ConfigurationError, KeyError
          false
        end

        def present_record_card(context:, resource:, record:, chat:, call_id:)
          return unless chat && call_id.is_a?(String) && chat.current_for?(context)
          present_read_surface(context: context, chat: chat, call_id: call_id, key: RECORD_CARD_KEY,
            props: { "resource" => resource.key.to_s, "record_id" => record.id.to_s })
        end

        def present_record_table(context:, resource:, ids:, scope:, query:, sort:, direction:, omitted:, chat:, call_id:)
          return unless chat && call_id.is_a?(String) && chat.current_for?(context)
          present_read_surface(context: context, chat: chat, call_id: call_id, key: RECORD_TABLE_KEY,
            props: {
              "resource" => resource.key.to_s,
              "ids" => Array(ids).first(20).map(&:to_s),
              "scope" => scope&.to_s,
              "query" => query.presence&.to_s&.first(200),
              "sort" => sort&.to_s,
              "direction" => %w[asc desc].include?(direction) ? direction : nil,
              "omitted" => omitted.to_i
            })
        end

        def present_metric_card(context:, resource:, result:, query:, filters:, any_filters:, relation_filters:, chat:, call_id:)
          return unless chat && call_id.is_a?(String) && chat.current_for?(context)
          filters_json = filters&.any? ? JSON.generate(filters) : nil
          any_json = any_filters&.any? ? JSON.generate(any_filters) : nil
          relation_filters_json = relation_filters&.any? ? JSON.generate(relation_filters) : nil
          return if [ filters_json, any_json, relation_filters_json ].any? { |text| text && text.bytesize > 4096 }
          present_read_surface(context: context, chat: chat, call_id: call_id, key: METRIC_CARD_KEY,
            props: {
              "resource" => resource.key.to_s,
              "function" => result.function.to_s,
              "field" => result.field&.name&.to_s,
              "group_by" => result.group_by&.name&.to_s,
              "period" => result.period&.to_s,
              "scope" => result.scope&.to_s,
              "query" => query.presence&.to_s&.first(200),
              "filters_json" => filters_json,
              "any_json" => any_json,
              "relation_filters_json" => relation_filters_json,
              "computed_at" => Time.current.utc.iso8601
            })
        end

        def present_task_progress(context:, task_id:, chat:, call_id:)
          return unless chat && call_id.is_a?(String) && chat.current_for?(context)
          present_read_surface(context: context, chat: chat, call_id: call_id, key: TASK_PROGRESS_KEY,
            props: { "task_id" => task_id.to_s })
        end

        def present_execution_receipt(context:, run_id:, chat:, call_id:)
          return unless chat && call_id.is_a?(String) && chat.current_for?(context)
          present_read_surface(context: context, chat: chat, call_id: call_id, key: EXECUTION_RECEIPT_KEY,
            props: { "run_id" => run_id.to_s })
        end

        def present_editable_form(context:, resource:, definition:, record:, intent_ref:, input:, chat: nil, call_id: nil)
          ensure_registered!
          if definition.custom?
            raise AccessDenied unless resource.surface_operation?(definition.key) && definition.scope == :member
          else
            raise AccessDenied unless chat && resource.assistant_change?(definition.key)
          end
          origin = chat ? "assistant" : "ui"
          raise AccessDenied unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
          run = OperationRun.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          unless run && run.resource_key == resource.key.to_s && run.operation == definition.key.to_s &&
              run.target_id == record.id&.to_s && run.status == "proposed" && run.origin == origin && run.parent_run_id.nil?
            raise AccessDenied
          end
          raise AccessDenied, "APPROVAL_EXPIRED" unless run.expires_at && run.expires_at > Time.current
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.security_version == context.security_version
          wire = canonical_input(input)
          raise AccessDenied, "APPROVAL_INVALIDATED" unless run.input_digest && run.input_digest == InputSchema.digest(input_values(context, resource, definition, record, wire))
          reference, correlation = if chat
            [ chat.context_reference, { adapter: ASSISTANT_ADAPTER, call_id: call_id, context: chat.context_reference } ]
          else
            [ "raa:intent:#{run.id}", { adapter: "raa_native_review", call_id: "editable:#{run.id}", context: "raa:intent:#{run.id}" } ]
          end
          with_context(context) do
            ::RailsToolViews.present(EDITABLE_FORM_KEY, props: { "intent" => run.id, "input" => wire },
              scope: scope_for(context), context: reference, correlation: correlation)
          end
        end

        def editable_form_review(context, props, state)
          active_intent = (state.is_a?(Hash) && state["intent"].presence) || props["intent"]
          active_input = (state.is_a?(Hash) && state["input"].presence) || props["input"]
          rev = review(context, { "intent" => active_intent, "input" => active_input })
          rev ? [ rev, active_input ] : nil
        end

        def authorize_editable_form(access)
          context = current_context
          return false unless context.is_a?(Context) && access.actor == context.actor_ref && access.tenant == context.tenant_ref
          state = access.surface&.state
          pair = editable_form_review(context, access.props, state)
          return false unless pair
          rev, = pair
          case access.operation
          when :present then rev.run.status == "proposed"
          when :read then rev.run.status != "succeeded" || receipt?(rev)
          when :action then %w[update_preview confirm dismiss].include?(access.action)
          else false
          end
        end

        def update_editable_preview(request)
          context = current_context
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          state = request.surface&.state || {}
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") if state["outcome"].present?
          pair = editable_form_review(context, request.props, state)
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless pair
          rev, = pair
          submitted = Array(request.arguments["entries"]).each_with_object({}) do |entry, acc|
            acc[entry["name"].to_s] = entry["value"] if entry.is_a?(Hash) && entry["name"].is_a?(String)
          end
          now = Time.current
          expired = OperationRun.where(id: rev.run.id, status: "proposed", approved_by_ref: nil,
            security_version: context.security_version)
            .where(OperationRun.arel_table[:expires_at].gt(now))
            .update_all(expires_at: now - 1.second, updated_at: now)
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") unless expired == 1

          proposal = Operations::Runner.new.preflight(
            context: context,
            resource: rev.resource,
            operation: rev.definition.key,
            target_id: rev.run.target_id,
            expected_version: rev.run.expected_version,
            input: submitted,
            origin: rev.run.origin.to_sym
          )
          if proposal.is_a?(Operations::Result)
            if proposal.code == "VALIDATION_FAILED"
              flat = proposal.errors.transform_values { |msgs| Array(msgs).first.to_s.truncate(200) }
              raise ::RailsToolViews::ValidationError.new(fields: flat.presence || { "base" => "is invalid" }, values: submitted)
            end
            raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: TERMINAL.fetch(proposal.code, "Preview could not be updated."))
          end
          new_wire = canonical_input(wire_input(proposal.values))
          ::RailsToolViews::Transition.new(state: { "intent" => proposal.intent.id, "input" => new_wire },
            agent: false, notice: "Preview updated. Confirm to apply.")
        end

        def confirm_editable_form(request)
          context = current_context
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          state = request.surface&.state || {}
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") if state["outcome"].present?
          active_intent = state["intent"].presence || request.props["intent"]
          active_wire = state["input"].presence || request.props["input"]
          if request.arguments["confirmed_intent"] != active_intent
            raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "Update the preview before confirming edited inputs.")
          end
          pair = editable_form_review(context, request.props, state)
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless pair
          rev, = pair
          run = rev.run
          result = Operations::Runner.new.execute(context: context, intent_ref: run.id, input: JSON.parse(active_wire),
            human_confirmed: true, origin: :surface, binding: { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id })
          if result.success?
            message = result.replayed ? "This operation was already completed. No second change was made." : "Operation completed."
            continue_chat(context, request, rev, "The change was applied.")
            ::RailsToolViews::Transition.new(state: state.merge("outcome" => "succeeded", "message" => message), agent: false)
          elsif TERMINAL.key?(result.code)
            continue_chat(context, request, rev, "It was not applied (#{result.code}): #{TERMINAL.fetch(result.code)}")
            ::RailsToolViews::Transition.new(state: state.merge("outcome" => "rejected", "code" => result.code, "message" => TERMINAL.fetch(result.code)), agent: false)
          elsif result.code == "NOT_FOUND"
            raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403)
          else
            raise ::RailsToolViews::Error.new("OPERATION_FAILED", status: 503, message: "The operation could not complete.")
          end
        end

        def dismiss_editable_form(request)
          context = current_context
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          state = request.surface&.state || {}
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") if state["outcome"].present?
          pair = editable_form_review(context, request.props, state)
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless pair
          rev, = pair
          now = Time.current
          expired = OperationRun.where(id: rev.run.id, status: "proposed", approved_by_ref: nil,
            security_version: context.security_version)
            .where(OperationRun.arel_table[:expires_at].gt(now))
            .update_all(expires_at: now - 1.second, updated_at: now)
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") unless expired == 1
          continue_chat(context, request, rev, "Nothing was changed.", decision: "dismissed")
          ::RailsToolViews::Transition.new(state: state.merge("outcome" => "dismissed", "message" => "Dismissed. Nothing was changed."), agent: false)
        end

        def authorize_task_progress(access)
          context = current_context
          return false unless context.is_a?(Context) && access.actor == context.actor_ref && access.tenant == context.tenant_ref
          props = access.props
          return false unless props.is_a?(Hash) && props["task_id"].is_a?(String)
          task = Tasks::Coordinator.find_visible!(context: context, id: props["task_id"])
          case access.operation
          when :present, :read then true
          when :action
            return false unless access.action == "cancel" && task.operation_run_id.present?
            resource = RailsAiAdmin.registry.fetch(task.resource_key)
            Authorization::Access.new(context, resource).authorize_cancel!(task.operation)
            true
          else false
          end
        rescue AccessDenied, ConfigurationError, KeyError
          false
        end

        def cancel_task_surface(request)
          context = current_context
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          task = Tasks::Coordinator.find_visible!(context: context, id: request.props["task_id"])
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless task.operation_run_id
          run = Collections::Contract.owned(context, task.operation_run_id, lock: true)
          resource, = Collections::Contract.definition(run)
          Authorization::Access.new(context, resource).authorize_cancel!(run.operation)
          changed = run.status == "proposed" || Collections::Contract::ACTIVE.include?(run.status)
          if run.status == "proposed"
            run.update!(status: "cancelled", cancellation_requested_at: Time.current, completed_at: Time.current)
          elsif Collections::Contract::ACTIVE.include?(run.status)
            run.update!(cancellation_requested_at: Time.current)
            Collections::Contract.stop_remaining!(run, "CANCELLED")
          end
          if changed
            Tasks::Coordinator.sync_from_run!(run, actor_ref: context.actor_ref)
            AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
              resource_key: run.resource_key, operation: run.operation, status: "cancelled",
              code: "CANCELLED", correlation_ref: run.id, origin: "surface", changed_fields: [], created_at: Time.current)
          end
          ::RailsToolViews::Transition.new(state: { "outcome" => "cancelled" }, agent: false)
        rescue AccessDenied
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403)
        end

        def task_progress_data(props)
          context = current_context
          return unless context.is_a?(Context) && props.is_a?(Hash) && props["task_id"].is_a?(String)
          task = Tasks::Coordinator.find_visible!(context: context, id: props["task_id"])
          eff = Tasks::Coordinator.effective_status(task)
          meta = task.summary_metadata || {}
          cancellable = begin
            if task.operation_run_id && eff == "executing"
              resource = RailsAiAdmin.registry.fetch(task.resource_key)
              Authorization::Access.new(context, resource).authorize_cancel!(task.operation)
              true
            else
              false
            end
          rescue AccessDenied
            false
          end
          TaskProgressData.new(task: task, effective_status: eff,
            succeeded_count: meta["succeeded_count"].to_i, failed_count: meta["failed_count"].to_i,
            total_count: [ meta["total_count"].to_i, 1 ].max, can_cancel: cancellable)
        rescue AccessDenied, ConfigurationError, KeyError
          nil
        end

        def execution_receipt_authorized?(context, run_id)
          return false unless run_id.is_a?(String) && run_id.match?(/\A[0-9a-f-]{36}\z/)
          run = OperationRun.find_by(id: run_id, tenant_ref: context.tenant_ref)
          return false unless run && run.status != "proposed"
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          access = Authorization::Access.new(context, resource)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          record = run.record_id ? access.find!(run.record_id) : nil
          authorize_execution_receipt!(context, access, definition, run, record)
          true
        rescue AccessDenied, ConfigurationError, KeyError
          false
        end

        # A custom operation's receipt follows read_operation_receipt?. A
        # native write's receipt shows who changed which fields, so another
        # actor needs the record history grant, as on the record's History.
        def authorize_execution_receipt!(context, access, definition, run, record)
          return access.authorize_receipt!(run.operation, record) if definition.custom?
          raise AccessDenied unless record
          proposer = OperationRun.column_names.include?("proposed_by_actor_ref") ? run.proposed_by_actor_ref : nil
          return true if run.actor_ref == context.actor_ref || proposer == context.actor_ref
          access.authorize_history!(record)
        end

        def execution_receipt_data(props)
          context = current_context
          return unless context.is_a?(Context) && props.is_a?(Hash) && props["run_id"].is_a?(String)
          run = OperationRun.find_by(id: props["run_id"], tenant_ref: context.tenant_ref)
          return unless run && run.status != "proposed"
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          access = Authorization::Access.new(context, resource)
          record = run.record_id ? access.find!(run.record_id) : nil
          authorize_execution_receipt!(context, access, definition, run, record)
          readable_names = access.fields(:read, record, view: :show).map { |f| f.name.to_s }
          audit = run.audit_event_id ? AuditEvent.find_by(id: run.audit_event_id) : nil
          changed = Array(audit&.changed_fields).map(&:to_s) & readable_names
          work = WorkItem.where(operation_run_id: run.id).filter_map do |item|
            access.authorize_delivery!(run.operation, item.kind, record)
            item.status
          rescue AccessDenied
            nil
          end.tally.freeze
          task = Tasks::Coordinator.available? ? AdminTask.find_by(operation_run_id: run.id) : nil
          can_undo = task ? Tasks::Coordinator.can_undo?(context, task) : false
          ver_status = OperationRun.column_names.include?("verification_status") ? run.verification_status : nil
          ver_checks = OperationRun.column_names.include?("verification_report") ? Array(run.verification_report) : []
          label = record ? access.record_label(record) : "#{resource.label.singularize} ##{run.record_id || run.target_id}"
          ExecutionReceiptData.new(run: run, resource: resource, operation_label: definition.description,
            record_label: label, changed_fields: changed, verification_status: ver_status,
            verification_checks: ver_checks, work_statuses: work, audit_event_id: run.audit_event_id,
            task_id: task&.id, can_undo: can_undo)
        rescue AccessDenied, ConfigurationError, KeyError
          nil
        end

        # Live, permission-checked data loaders for read-only Surfaces. Never
        # trust stored record values; re-query and re-authorize on every render.
        def record_card_data(props)
          context = current_context
          return unless context.is_a?(Context) && props.is_a?(Hash)
          resource = RailsAiAdmin.registry.fetch(props["resource"].to_s)
          access = Authorization::Access.new(context, resource)
          access.authorize_assistant!
          record_id = props["record_id"].to_s
          return unless access.canonical_id?(record_id)
          record = access.find!(record_id)
          readable = access.fields(:read, record, view: :show)
          projected = access.project(record, view: :show)
          resolver = Fields::Association.new(context, resource, assistant: true)
          fields = readable.filter_map do |field|
            next unless projected.key?(field.name.to_s)
            [ field, native_text(field, projected[field.name.to_s], resolver, context) ]
          end
          RecordCardData.new(resource: resource, record: record, label: access.record_label(record, view: :show), fields: fields)
        rescue AccessDenied, ConfigurationError, KeyError
          nil
        end

        def record_table_data(props)
          context = current_context
          return unless context.is_a?(Context) && props.is_a?(Hash)
          resource = RailsAiAdmin.registry.fetch(props["resource"].to_s)
          access = Authorization::Access.new(context, resource)
          access.authorize_assistant!
          access.authorize!(:index)
          ids = Array(props["ids"]).first(20).select { |id| id.is_a?(String) && access.canonical_id?(id) }
          found = ids.any? ? access.relation.where(resource.model_class.primary_key => ids).index_by { |record| record.id.to_s } : {}
          columns = access.fields(:read, nil, view: :index).first(MAX_TABLE_COLUMNS)
          resolver = Fields::Association.new(context, resource, assistant: true)
          visible_records = ids.filter_map do |id|
            record = found[id]
            next unless record
            access.authorize!(:show, record)
            record
          rescue AccessDenied
            nil
          end
          columns.select { |field| field.scalar_type == :belongs_to }.each do |field|
            resolver.prime(field, visible_records.filter_map { |record| record.has_attribute?(field.column) ? record.read_attribute(field.column)&.to_s : nil })
          end
          rows = visible_records.map do |record|
            projected = access.project(record, view: :index)
            cells = columns.map do |field|
              projected.key?(field.name.to_s) ? native_text(field, projected[field.name.to_s], resolver, context) : "—"
            end
            { id: record.id.to_s, label: access.record_label(record, view: :index), cells: cells }
          end
          omitted = props["omitted"].to_i + (ids.size - rows.size)
          RecordTableData.new(resource: resource, columns: columns, rows: rows, omitted: omitted,
            scope: props["scope"], query: props["query"], sort: props["sort"], direction: props["direction"])
        rescue AccessDenied, ConfigurationError, KeyError
          nil
        end

        def metric_card_data(props)
          context = current_context
          return unless context.is_a?(Context) && props.is_a?(Hash)
          resource = RailsAiAdmin.registry.fetch(props["resource"].to_s)
          access = Authorization::Access.new(context, resource)
          access.authorize_assistant!
          filters = parse_optional_json(props["filters_json"])
          any_filters = parse_optional_json(props["any_json"])
          relation_filters = parse_optional_json(props["relation_filters_json"])
          scope_arg = props["scope"].present? ? props["scope"] : Queries::NamedScope::NONE
          result = Queries::List.new(context, resource, assistant: true).aggregate(
            function: props["function"].to_s, field: props["field"].presence, group_by: props["group_by"].presence,
            period: props["period"].presence, search: props["query"].presence, scope: scope_arg,
            filters: filters, any_filters: any_filters, relation_filters: relation_filters
          )
          resolver = Fields::Association.new(context, resource, assistant: true)
          if result.group_by&.scalar_type == :belongs_to
            resolver.prime(result.group_by, result.groups.filter_map { |group| group.key&.to_s })
          end
          value_text = result.field ? format_metric_value(result.field, result.function, result.value, context) : result.count.to_s
          groups = result.groups.map do |group|
            label = if result.period
              group.key ? group.key.iso8601 : "—"
            else
              native_text(result.group_by, group.key, resolver, context)
            end
            { label: label, count: group.count, value_text: result.field ? format_metric_value(result.field, result.function, group.value, context) : nil }
          end
          filters_summary = summarize_metric_filters(access, filters, any_filters, relation_filters)
          zone = result.period && result.group_by&.scalar_type == :datetime ? context.time_zone : nil
          MetricCardData.new(resource: resource, aggregate: result, value_text: value_text, groups: groups,
            scope: result.scope, query: props["query"], filters_summary: filters_summary, time_zone: zone, computed_at: props["computed_at"])
        rescue AccessDenied, ConfigurationError, KeyError, JSON::JSONError
          nil
        end

        # The record a review is about: a new one for a proposed create, the
        # created one afterwards, and none once a delete succeeded.
        def review_record(access, run)
          case run.operation
          when "create" then run.status == "succeeded" ? access.find!(run.record_id) : access.relation.new
          when "destroy" then run.status == "succeeded" ? nil : access.find!(run.target_id)
          else access.find!(run.target_id)
          end
        end

        # How a review names its record in the conversation and on the card.
        def subject(review)
          singular = review.resource.label.singularize
          return "#{singular} ##{review.run.target_id}" if review.record.nil?
          return "a new #{singular.downcase_first}" unless review.record.persisted?
          review.access.record_label(review.record)
        end

        def receipt?(review)
          # A native change's result is the record itself, behind its list grant.
          return review.access.authorize!(:index) unless review.definition.custom?
          review.access.authorize_receipt!(review.definition.key, review.record)
        rescue AccessDenied
          false
        end

        # The human's own submission of the Surface form is the confirmation.
        def confirm(request)
          context = current_context
          review = review(context, request.props) if context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless review
          if request.respond_to?(:surface) && request.surface&.state.is_a?(Hash) && request.surface.state["outcome"].present?
            raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.")
          end
          run = review.run
          result = Operations::Runner.new.execute(context: context, intent_ref: run.id, input: JSON.parse(request.props.fetch("input")),
            human_confirmed: true, origin: :surface, binding: { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id })
          if result.success?
            message = result.replayed ? "This operation was already completed. No second change was made." : "Operation completed."
            applied = run.operation == "create" ? "The record was created with id #{result.record_id}." : "The change was applied."
            continue_chat(context, request, review, result.replayed ? "It had already been applied; no second change was made." : applied)
            ::RailsToolViews::Transition.new(state: { "outcome" => "succeeded", "message" => message }, agent: false)
          elsif TERMINAL.key?(result.code)
            continue_chat(context, request, review, "It was not applied (#{result.code}): #{TERMINAL.fetch(result.code)}")
            ::RailsToolViews::Transition.new(state: { "outcome" => "rejected", "code" => result.code, "message" => TERMINAL.fetch(result.code) }, agent: false)
          elsif result.code == "NOT_FOUND"
            raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403)
          else
            # Nothing committed; the Surface revision is unchanged and retry is safe.
            raise ::RailsToolViews::Error.new("OPERATION_FAILED", status: 503, message: "The operation could not complete. Nothing was changed; try again.")
          end
        end

        # Declining is a decision too (RAA-019): the unapproved intent expires
        # at once, nothing else changes, and a chat hears about it once.
        def dismiss(request)
          context = current_context
          review = review(context, request.props) if context && request.actor == context.actor_ref && request.tenant == context.tenant_ref
          raise ::RailsToolViews::Error.new("NOT_ALLOWED", status: 403) unless review
          if request.respond_to?(:surface) && request.surface&.state.is_a?(Hash) && request.surface.state["outcome"].present?
            raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.")
          end
          now = Time.current
          expired = OperationRun.where(id: review.run.id, status: "proposed", approved_by_ref: nil,
            security_version: context.security_version)
            .where(OperationRun.arel_table[:expires_at].gt(now))
            .update_all(expires_at: now - 1.second, updated_at: now)
          raise ::RailsToolViews::Error.new("CONFLICT", status: 409, message: "This review was already decided.") unless expired == 1
          continue_chat(context, request, review, "Nothing was changed.", decision: "dismissed")
          ::RailsToolViews::Transition.new(state: { "outcome" => "dismissed", "message" => "Dismissed. Nothing was changed." }, agent: false)
        end

        # The visible before/after values the operation's pure preflight
        # proposes, as the native confirmation page shows them. Empty once the
        # review cannot be confirmed or the preview is no longer valid.
        def proposed_changes(review, wire)
          return [] unless review.run.status == "proposed"
          return native_changes(review, wire) unless review.definition.custom?
          context = review.access.context
          preview = Operations::Runner.new.preview(context: context, resource: review.resource, operation: review.definition.key,
            target_id: review.record.id, expected_version: review.run.expected_version, input: JSON.parse(wire), origin: :surface)
          return [] unless preview.is_a?(Operations::Runner::Preview)
          readable = review.access.fields(:read, review.record, view: :show).index_by { |field| field.name.to_s }
          preview.changes.filter_map do |name, change|
            field = readable[name]
            next unless field
            [ field, field.format(change["before"], time_zone: context.time_zone), field.format(change["after"], time_zone: context.time_zone) ]
          end
        rescue AccessDenied, ConfigurationError, JSON::ParserError
          []
        end

        # Typed display values. While proposed, only the actor's current input
        # grants; once committed, the recorded input through the operation's
        # declared contract (as receipt replay does), behind the receipt grant.
        def display_values(review, wire)
          # Native changes show before and after instead (native_changes).
          return [] unless review.definition.custom?
          values = JSON.parse(wire)
          fields = if review.run.status == "succeeded"
            review.definition.handler_class.input
          else
            begin
              review.definition.fields(review.access, review.record)
            rescue AccessDenied
              []
            end
          end
          fields.filter_map do |field|
            next unless values.key?(field.name.to_s)
            text = begin
              field.format(field.coerce(values[field.name.to_s], time_zone: review.access.context.time_zone), time_zone: review.access.context.time_zone)
            rescue ArgumentError
              "Unavailable"
            end
            [ field, text ]
          end
        rescue JSON::ParserError
          []
        end

        # Before and after for a native create or update, through the actor's
        # read grants; references show their labels. A field the actor may
        # write but not read shows only that it will be set.
        def native_changes(review, wire)
          return [] if review.run.operation == "destroy"
          context = review.access.context
          values = input_values(context, review.resource, review.definition, review.record, wire)
          persisted = review.record.persisted?
          readable = review.access.fields(:read, persisted ? review.record : nil, view: :show).index_by { |field| field.name.to_s }
          current = persisted ? review.access.project(review.record, view: :show) : {}
          resolver = Fields::Association.new(context, review.resource)
          fields = review.resource.fields.index_by { |field| field.name.to_s }
          values.filter_map do |name, after|
            field = fields[name]
            next unless field
            before = current[name]
            next if persisted && before == after
            show = ->(value) { readable.key?(name) ? native_text(field, value, resolver, context) : I18n.t("rails_ai_admin.surfaces.hidden_value") }
            [ field, persisted ? show.call(before) : "—", show.call(after) ]
          end
        rescue AccessDenied, ConfigurationError, JSON::ParserError
          []
        end

        def native_text(field, value, resolver, context)
          return "—" if value.nil?
          case field.scalar_type
          when :belongs_to then resolver.reference(field, value.to_s).label.to_s
          when :references then Array(value).map { |id| resolver.reference(field, id).label.to_s }.join(", ").presence || "—"
          else field.format(value, time_zone: context.time_zone)
          end
        end

        private

        # Same transaction as the Surface revision; nothing is admitted when
        # the confirmation rolls back.
        def continue_chat(context, request, review, outcome, decision: "confirmed")
          return unless RailsAiAdmin.configuration.assistant
          require "rails_ai_admin/assistant"
          Assistant::Continuation.admit!(context: context, context_ref: request.context_ref, review: review, outcome: outcome, decision: decision)
        rescue AccessDenied
          # A closed chat never blocks the human's committed business outcome.
          nil
        end

        def verify_if_present(key)
          component = begin
            ::RailsToolViews.registry.fetch(key)
          rescue ::RailsToolViews::Error => error
            raise unless error.code == "UNKNOWN_COMPONENT"
            return nil
          end
          yield component
        end

        def ensure_component(key)
          ::RailsToolViews.registry.fetch(key)
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "UNKNOWN_COMPONENT"
          yield
        end

        def present_read_surface(context:, chat:, call_id:, key:, props:)
          ensure_registered!
          reference = chat.context_reference
          with_context(context) do
            ::RailsToolViews.present(key, props: props, scope: scope_for(context), context: reference,
              correlation: { adapter: ASSISTANT_ADAPTER, call_id: call_id, context: reference })
          end
        end

        def parse_optional_json(text)
          return nil if text.nil? || text.empty?
          JSON.parse(text, max_nesting: 8)
        end

        def summarize_metric_filters(access, filters, any_filters, relation_filters)
          by_name = access.fields(:filter).index_by { |field| field.name.to_s }
          parts = []
          if filters.is_a?(Hash)
            filters.each do |name, ops|
              label = by_name[name.to_s]&.label || name.to_s
              ops.each { |op, val| parts << "#{label} #{op} #{Array(val).join(',')}" } if ops.is_a?(Hash)
            end
          end
          parts << "OR (#{any_filters.size})" if any_filters.is_a?(Array) && any_filters.any?
          parts.concat(relation_filters.keys.map { |rel| "#{rel}.*" }) if relation_filters.is_a?(Hash) && relation_filters.any?
          parts.any? ? parts.first(6).join(", ").truncate(160) : nil
        end

        def format_metric_value(field, function, value, context)
          return "—" if value.nil?
          if function == "average"
            places = (field.scalar_type == :decimal ? field.decimal_limits[:scale].to_i : 0) + 2
            whole, fraction = value.round(places).to_s("F").split(".")
            return "#{whole}.#{fraction.to_s.ljust(places, '0')}"
          end
          field.format(value, time_zone: context.time_zone)
        end

        def register
          ::RailsToolViews.register(KEY, description: "Admin operation review", version: VERSION, schema: SCHEMA, partial: PARTIAL,
            policy: POLICY, actions: { confirm: { schema: CONFIRM_SCHEMA, policy: POLICY, handler: CONFIRM },
              dismiss: { schema: CONFIRM_SCHEMA, policy: POLICY, handler: DISMISS } }, expose_to: [])
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "DUPLICATE_COMPONENT"
          ::RailsToolViews.registry.fetch(KEY)
        end

        def register_read_component(key, spec)
          ::RailsToolViews.register(key, description: spec.fetch(:description), version: VERSION, schema: spec.fetch(:schema),
            partial: spec.fetch(:partial), policy: READ_POLICY, actions: {}, expose_to: [])
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "DUPLICATE_COMPONENT"
          ::RailsToolViews.registry.fetch(key)
        end

        def register_task_progress
          ::RailsToolViews.register(TASK_PROGRESS_KEY, description: "Admin background task progress", version: VERSION,
            schema: TASK_PROGRESS_SCHEMA, partial: TASK_PROGRESS_PARTIAL, policy: TASK_PROGRESS_POLICY,
            actions: { cancel: { schema: CONFIRM_SCHEMA, policy: TASK_PROGRESS_POLICY, handler: CANCEL_TASK } }, expose_to: [])
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "DUPLICATE_COMPONENT"
          ::RailsToolViews.registry.fetch(TASK_PROGRESS_KEY)
        end

        def register_editable_form
          ::RailsToolViews.register(EDITABLE_FORM_KEY, description: "Admin editable operation review", version: VERSION,
            schema: SCHEMA, partial: EDITABLE_FORM_PARTIAL, policy: EDITABLE_FORM_POLICY,
            actions: {
              update_preview: { schema: UPDATE_PREVIEW_SCHEMA, policy: EDITABLE_FORM_POLICY, handler: UPDATE_EDITABLE_PREVIEW },
              confirm: { schema: EDITABLE_CONFIRM_SCHEMA, policy: EDITABLE_FORM_POLICY, handler: CONFIRM_EDITABLE_FORM },
              dismiss: { schema: CONFIRM_SCHEMA, policy: EDITABLE_FORM_POLICY, handler: DISMISS_EDITABLE_FORM }
            }, expose_to: [])
        rescue ::RailsToolViews::Error => error
          raise unless error.code == "DUPLICATE_COMPONENT"
          ::RailsToolViews.registry.fetch(EDITABLE_FORM_KEY)
        end

        def canonical_input(input)
          raise AccessDenied, "INVALID_QUERY" unless input.is_a?(Hash)
          stringified = input.to_h { |key, value| [ key.to_s, value ] }
          wire = JSON.generate(stringified.sort.to_h)
          raise AccessDenied, "INVALID_QUERY" if wire.bytesize > MAX_INPUT_BYTES
          wire
        end

        def input_values(context, resource, definition, record, wire)
          access = Authorization::Access.new(context, resource)
          result = InputSchema.new(definition.fields(access, record), partial: definition.key == "update" && !definition.custom?).coerce(JSON.parse(wire), time_zone: context.time_zone)
          raise AccessDenied, "APPROVAL_INVALIDATED" unless result.valid?
          result.values
        end
      end

      POLICY = ->(access) { ToolViews.authorize(access) }
      READ_POLICY = ->(access) { ToolViews.authorize_read(access) }
      TASK_PROGRESS_POLICY = ->(access) { ToolViews.authorize_task_progress(access) }
      EDITABLE_FORM_POLICY = ->(access) { ToolViews.authorize_editable_form(access) }
      CONFIRM = ->(request) { ToolViews.confirm(request) }
      DISMISS = ->(request) { ToolViews.dismiss(request) }
      CANCEL_TASK = ->(request) { ToolViews.cancel_task_surface(request) }
      UPDATE_EDITABLE_PREVIEW = ->(request) { ToolViews.update_editable_preview(request) }
      CONFIRM_EDITABLE_FORM = ->(request) { ToolViews.confirm_editable_form(request) }
      DISMISS_EDITABLE_FORM = ->(request) { ToolViews.dismiss_editable_form(request) }
    end
  end
end
