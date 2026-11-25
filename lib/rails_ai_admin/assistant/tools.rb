# frozen_string_literal: true

require "json"

module RailsAiAdmin
  module Assistant
    # Tool state for one claimed turn: the freshly resolved Context, the chat
    # and a fence that stops a worker whose lease was reassigned.
    # conversation is the server-owned reference of a session without a chat
    # (an MCP client); its proposals become reviews opened by URL.
    # Reviews proposed during one turn (or one MCP request). A model asked to
    # change every record would otherwise queue a review per record.
    # Only prepared reviews count; a refused proposal does not.
    class ProposalTally
      LIMIT = 3

      def initialize
        @count = 0
      end

      def full? = @count >= LIMIT
      def record! = @count += 1
    end

    Session = ::Data.define(:context, :chat, :fence, :conversation, :tally) do
      def initialize(context:, chat:, fence:, conversation: nil, tally: ProposalTally.new) = super
      # Registered resources this actor may currently expose to the model.
      def resources
        RailsAiAdmin.registry.resources.select { |resource| exposed?(resource) }
      end

      # Unknown, hidden and unexposed resources are indistinguishable.
      def resource(key)
        raise AccessDenied unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
        resource = RailsAiAdmin.registry.fetch(key)
        raise AccessDenied unless exposed?(resource)
        resource
      rescue ConfigurationError, KeyError
        raise AccessDenied
      end

      def access(resource) = Authorization::Access.new(context, resource)

      private

      def exposed?(resource)
        access(resource).authorize_assistant!
      rescue AccessDenied
        false
      end
    end

    # Base for admin tools. Each call checks the turn fence and current grants.
    # Results are bounded JSON data for the model; they grant nothing.
    class Tool < ::RubyLLM::Tool
      MAX_RESULT_BYTES = 16_384
      # One filter value: a scalar, or a list of scalars for "in".
      FILTER_VALUE_SCHEMA = { "anyOf" => [ { "type" => %w[string number boolean] },
        { "type" => "array", "maxItems" => Field::MAX_IN_VALUES, "items" => { "type" => %w[string number boolean] } } ] }.freeze
      RELATED_TERMS_SCHEMA = { "type" => "object", "minProperties" => 1, "additionalProperties" => false,
        "properties" => { "_query" => { "type" => "string", "minLength" => 1, "maxLength" => 200 } },
        "patternProperties" => { "^[a-z][a-z0-9_]*$" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } } }.freeze
      RELATION_FILTERS_SCHEMA = { "type" => "object", "maxProperties" => Queries::List::MAX_RELATION_FILTERS,
        "description" => "Single-hop relations from describe_resource. Use target field filters and/or _query for target search, _exists for presence, or _none around terms to exclude matches.",
        "additionalProperties" => { "oneOf" => [ RELATED_TERMS_SCHEMA,
          { "type" => "object", "required" => [ "_exists" ], "additionalProperties" => false, "properties" => { "_exists" => { "type" => "boolean" } } },
          { "type" => "object", "required" => [ "_none" ], "additionalProperties" => false, "properties" => { "_none" => RELATED_TERMS_SCHEMA } } ] } }.freeze
      MESSAGES = {
        "NOT_FOUND" => "Not found or not available to this user.",
        "INVALID_QUERY" => "The request was not valid for this resource.",
        "CONFLICT" => "The record changed. Fetch it again before proposing a change.",
        "VALIDATION_FAILED" => "The proposed input is not valid.",
        "UNAVAILABLE" => "This capability is not available.",
        "LIMIT_REACHED" => "At most #{ProposalTally::LIMIT} reviews can be proposed in one reply. Ask the user to review these first; " \
          "for the same change on many records, use propose_bulk_change when describe_resource lists bulk_update.",
        "TOO_MANY" => "More than #{Selections::Builder::LIMIT} records match. Ask the user to narrow the request."
      }.freeze

      def initialize(session)
        super()
        @session = session
      end

      def execute(tool_call: nil, **arguments)
        @session.fence.call
        bounded(perform(tool_call: tool_call, **arguments))
      rescue ArgumentError
        # Missing or unknown model-supplied keywords.
        failure("INVALID_QUERY")
      rescue AccessDenied => error
        failure(error.code == "INVALID_QUERY" ? "INVALID_QUERY" : error.code == "CONFLICT" ? "CONFLICT" : "NOT_FOUND")
      rescue ConfigurationError
        failure("UNAVAILABLE")
      end

      private

      def failure(code, **extra) = { "error" => code, "message" => MESSAGES.fetch(code, MESSAGES["UNAVAILABLE"]), **extra }

      # A chat shows the review in the conversation; a session without one
      # (MCP) records it under its conversation reference for the person to
      # open in the admin.
      def present_review(tool_views, resource, definition, record, proposal, tool_call)
        common = { context: @session.context, resource: resource, definition: definition, record: record,
          intent_ref: proposal.intent.id, input: tool_views.wire_input(proposal.values) }
        if @session.chat
          tool_views.present(**common, chat: @session.chat, call_id: tool_call.id)
        else
          tool_views.present(**common, assistant_call: { conversation: @session.conversation, call_id: tool_call.id })
        end
      end

      def acknowledgment(surface)
        message = @session.chat ? "A review is shown to the user. Nothing has changed yet; a later message reports the confirmed result." :
          "A review is waiting in the admin. Nothing has changed until the user opens review_url and confirms it."
        { "status" => "awaiting_human_confirmation", "surface" => surface.id, "message" => message }
      end

      def bounded(result)
        raise ConfigurationError, "Tool result must be a Hash" unless result.is_a?(Hash)
        return result if JSON.generate(result).bytesize <= MAX_RESULT_BYTES
        if result["records"].is_a?(Array)
          records = result["records"].dup
          records.pop while records.any? && JSON.generate(result.merge("records" => records, "truncated" => true)).bytesize > MAX_RESULT_BYTES
          return result.merge("records" => records, "truncated" => true)
        end
        failure("UNAVAILABLE")
      end

      def time_zone = @session.context.time_zone

      # Typed JSON for the model (RAA-017): null stays null, booleans and
      # integers keep their JSON types, decimals are exact strings padded to
      # their scale, dates and times are ISO 8601, a select is {value, label}
      # and a reference is {id, label, resource}. A registered field type keeps
      # its formatted text, because its formatter may deliberately redact.
      def typed(field, value, references)
        return nil if value.nil?
        return field.format(value, time_zone: time_zone).truncate(500) if field.plugin?
        case field.scalar_type
        when :boolean, :integer then value
        when :decimal then field.format_decimal(value)
        when :date then value.iso8601
        when :datetime then value.in_time_zone(time_zone).iso8601
        when :time then field.format(value, time_zone: time_zone)
        when :json then JSON.generate(value).truncate(2000)
        when :references
          Array(value).first(50).map do |id|
            reference = references.reference(field, id)
            { "id" => reference.id, "label" => reference.label.to_s.truncate(200), "resource" => reference.visible ? reference.resource_key.to_s : nil }
          end
        when :rich_text then field.format(value, time_zone: time_zone).truncate(2000)
        when :files then Array(value).map { |file| { "filename" => file.filename.truncate(200), "content_type" => file.content_type, "byte_size" => file.byte_size } }
        when :file then { "filename" => value.filename.truncate(200), "content_type" => value.content_type, "byte_size" => value.byte_size }
        when :select then { "value" => value.to_s, "label" => field.format(value, time_zone: time_zone) }
        when :belongs_to
          reference = references.reference(field, value.to_s)
          { "id" => reference.id, "label" => reference.label.to_s.truncate(200), "resource" => reference.visible ? reference.resource_key.to_s : nil }
        else value.to_s.truncate(500)
        end
      end

      def values(access, record, view, references)
        fields = access.fields(:read, record, view: view).index_by { |field| field.name.to_s }
        access.project(record, view: view).filter_map do |name, value|
          field = fields[name]
          [ name, typed(field, value, references) ] if field
        end.to_h
      end

      def reference_resolver(access) = Fields::Association.new(access.context, access.resource, assistant: true)

      def record_entry(access, record, view, references = reference_resolver(access))
        { "id" => record.id.to_s, "label" => access.record_label(record, view: view), "fields" => values(access, record, view, references) }
      end

      # Records the actor may list but not open are left out, as on the list
      # page (RAA-001), and counted so the model can say so.
      def record_entries(access, records, view)
        resolver = reference_resolver(access)
        access.fields(:read, nil, view: view).select { |field| field.scalar_type == :belongs_to }.each do |field|
          resolver.prime(field, records.filter_map { |record| record.has_attribute?(field.column) ? record.read_attribute(field.column)&.to_s : nil })
        end
        omitted = 0
        entries = records.filter_map do |record|
          record_entry(access, record, view, resolver)
        rescue AccessDenied
          omitted += 1
          nil
        end
        [ entries, omitted ]
      end

      def wire_filters(filters)
        return nil if filters.nil? || filters == {}
        raise AccessDenied, "INVALID_QUERY" unless filters.is_a?(Hash) && filters.size <= Queries::List::MAX_FILTER_CONDITIONS
        filters.to_h do |name, conditions|
          raise AccessDenied, "INVALID_QUERY" unless conditions.is_a?(Hash)
          [ name.to_s, conditions.to_h { |operator, value| [ operator.to_s, value.is_a?(Array) ? value.map { |item| scalar(item) } : scalar(value) ] } ]
        end
      end

      def wire_any_filters(any)
        return nil if any.nil? || any == []
        raise AccessDenied, "INVALID_QUERY" unless any.is_a?(Array) && any.size.between?(1, Queries::List::MAX_OR_GROUPS)
        any.map do |group|
          parsed = wire_filters(group)
          raise AccessDenied, "INVALID_QUERY" unless parsed&.any?
          parsed
        end
      end

      def wire_relation_filters(relations)
        return nil if relations.nil? || relations == {}
        raise AccessDenied, "INVALID_QUERY" unless relations.is_a?(Hash) && relations.size.between?(1, Queries::List::MAX_RELATION_FILTERS)
        relations.to_h do |name, nested|
          raise AccessDenied, "INVALID_QUERY" unless nested.is_a?(Hash) && nested.any?
          nested = nested.stringify_keys
          parsed = if nested.key?("_none")
            raise AccessDenied, "INVALID_QUERY" unless nested.one?
            { "_none" => wire_related_terms(nested["_none"]) }
          elsif nested.key?("_exists")
            nested
          else
            wire_related_terms(nested)
          end
          [ name.to_s, parsed ]
        end
      end

      def wire_related_terms(terms)
        raise AccessDenied, "INVALID_QUERY" unless terms.is_a?(Hash) && terms.any?
        terms = terms.stringify_keys
        terms.slice("_query").merge(wire_filters(terms.except("_query")) || {})
      end

      def present_read_view
        yield
      rescue ::RailsToolViews::Error, AccessDenied, ConfigurationError
        nil
      end

      def scalar(value)
        case value
        when String then value
        when Integer, Float, true, false then value.to_s
        else raise AccessDenied, "INVALID_QUERY"
        end
      end

      # The assistant sees the whole policy relation unless it names a granted
      # list tab; a default tab never applies silently (RAA-007).
      def list_scope(scope)
        return Queries::NamedScope::NONE if scope.nil?
        raise AccessDenied, "INVALID_QUERY" unless scope.is_a?(String) && scope.match?(Queries::NamedScope::NAME)
        scope
      end
    end

    class ListResources < Tool
      description "List the admin resources this user may ask about. Call this first to learn resource keys."
      parameters({ "type" => "object", "properties" => {}, "additionalProperties" => false })

      def self.tool_name = "list_resources"

      private

      def perform(tool_call:)
        { "resources" => @session.resources.map do |resource|
          entry = { "key" => resource.key.to_s, "label" => resource.label }
          entry["description"] = resource.description if resource.description
          entry
        end }
      end
    end

    class DescribeResource < Tool
      description "Describe one resource: readable fields, search, filters and the changes you may propose."
      parameters({ "type" => "object", "required" => [ "resource" ], "additionalProperties" => false,
        "properties" => { "resource" => { "type" => "string", "description" => "A key from list_resources" } } })

      def self.tool_name = "describe_resource"

      private

      def perform(tool_call:, resource:)
        resource = @session.resource(resource)
        access = @session.access(resource)
        result = {
          "key" => resource.key.to_s, "label" => resource.label,
          "fields" => access.fields(:read, nil, view: :show).map { |field| field_entry(field) },
          # Match mode per field: "prefix" means "Love" does not find "Ada Lovelace" (RAA-021).
          "search" => access.fields(:search, assistant: true).map { |field| { "field" => field.name.to_s, "match" => (field.options[:searchable] == true ? :prefix : field.options[:searchable]).to_s } },
          "filters" => access.fields(:filter).map { |field| { "field" => field.name.to_s, "operators" => field.filter_operators.map(&:to_s) } },
          "sort" => access.fields(:sort, assistant: true).map { |field| field.name.to_s },
          # aggregate_records: measured fields and their functions, and the
          # categories results can be grouped by (filter grant required).
          "aggregates" => access.fields(:read).select { |field| field.aggregatable? && !field.virtual? }
            .map { |field| { "field" => field.name.to_s, "functions" => field.aggregate_functions.map(&:to_s) } },
          "group_by" => access.fields(:filter).select { |field| Field::GROUP_TYPES.include?(field.scalar_type) }.map { |field| field.name.to_s },
          # Date and datetime fields aggregate_records can group by period.
          "group_by_period" => access.fields(:filter).select { |field| Field::PERIOD_TYPES.include?(field.scalar_type) }.map { |field| field.name.to_s },
          # Search and count apply no list tab unless one is named (RAA-007).
          "scopes" => access.named_scopes.map { |definition| { "name" => definition.name.to_s, "label" => definition.label, "default_in_ui" => definition.default? } }
        }
        result["description"] = resource.description if resource.description
        relations = Queries::List.new(@session.context, resource, assistant: true).filterable_relations
        if relations.any?
          result["filter_relations"] = relations.map do |spec|
            { "relation" => spec.name, "resource" => spec.resource.key.to_s, "kind" => spec.kind, "searchable" => spec.searchable,
              "filters" => spec.fields.map { |field| { "field" => field.name.to_s, "operators" => field.filter_operators.map(&:to_s) } } }
          end
        end
        if RailsAiAdmin.configuration.surfaces
          result["operations"] = operations(resource, access)
          result["changes"] = changes(resource, access)
        elsif resource.assistant_change?(:bulk_update) && bulk_granted?(access)
          result["changes"] = bulk_only_changes(resource, access)
        end
        result
      end

      def bulk_only_changes(resource, access)
        fields = access.fields(:write, nil, operation: :update)
          .reject { |field| ProposeChange::UNSUPPORTED.include?(field.scalar_type) }
          .map { |field| field_entry(field).merge("required" => false) }
        [ { "action" => "bulk_update", "fields" => fields, "max_records" => Selections::Builder.async_limit, "max_ids" => Selections::Builder::LIMIT } ]
      end

      # Native changes this resource lets the assistant propose, with the
      # fields the user may set on create or update (never passwords or files).
      def changes(resource, access)
        entries = %w[create update destroy].filter_map do |action|
          next unless resource.assistant_change?(action)
          entry = { "action" => action }
          unless action == "destroy"
            fields = access.fields(:write, action == "create" ? access.relation.new : nil, operation: action.to_sym)
              .reject { |field| ProposeChange::UNSUPPORTED.include?(field.scalar_type) }
            entry["fields"] = fields.map { |field| field_entry(field).merge("required" => action == "create" && field.options[:required] == true) }
          end
          entry
        end
        if resource.assistant_change?(:bulk_update) && bulk_granted?(access)
          update = entries.find { |entry| entry["action"] == "update" }
          entries << { "action" => "bulk_update", "fields" => update ? update["fields"] : [], "max_records" => Selections::Builder.async_limit, "max_ids" => Selections::Builder::LIMIT }
        end
        entries
      end

      def bulk_granted?(access)
        access.authorize_selection!
      rescue AccessDenied
        false
      end

      def field_entry(field)
        entry = { "name" => field.name.to_s, "label" => field.label, "type" => field.scalar_type.to_s }
        entry["description"] = field.options[:description] if field.options[:description]
        # Operation inputs declare enum values; without them a model can only guess.
        entry["choices"] = field.choice_options.map { |label, value| { "value" => value, "label" => label } } if %i[select enum].include?(field.scalar_type)
        entry
      end

      # Declared contracts only. Member grants depend on the record, so each
      # proposal is authorized against its record by propose_operation.
      def operations(resource, _access)
        RailsAiAdmin.operation_registry.custom(resource).filter_map do |definition|
          next unless definition.scope == :member && resource.assistant_operation?(definition.key) && resource.action_enabled?(definition.key)
          { "key" => definition.key.to_s, "description" => definition.description.to_s.truncate(200),
            "input" => definition.handler_class.input.map { |field| field_entry(field).merge("required" => field.options[:required] == true) } }
        end
      end
    end

    class SearchRecords < Tool
      PAGE_LIMIT = 20
      MAX_RECORDS = 1_000
      description "Search one resource's records with optional text, typed filters, a list scope and a sort. Returns up to 20 records. " \
        "Every record you may see is searched unless you pass scope. To count records, use count_records instead of paging. " \
        "When has_more is true, pass next_offset as offset to continue, including after truncation."
      parameters({ "type" => "object", "required" => [ "resource" ], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "query" => { "type" => "string", "maxLength" => 200, "description" => "Text matched against searchable fields with each field's match mode" },
          "filters" => { "type" => "object", "description" => "Field name to {operator: value} with operators from describe_resource: eq, in (a list of values), gte, lte, contains (part of the text) or blank (true for empty, false for not empty); use select values, not labels",
            "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } },
          "any" => { "type" => "array", "maxItems" => Queries::List::MAX_OR_GROUPS,
            "description" => "Optional OR filter groups (up to #{Queries::List::MAX_OR_GROUPS}); each item is a filters object whose conditions are ANDed, and the groups are ORed together",
            "items" => { "type" => "object", "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } } },
          "relation_filters" => RELATION_FILTERS_SCHEMA,
          "scope" => { "type" => "string", "description" => "Optional scope name from describe_resource" },
          "sort" => { "type" => "string", "description" => "Optional sortable field from describe_resource" },
          "direction" => { "type" => "string", "enum" => %w[asc desc] },
          "page" => { "type" => "integer", "minimum" => 1, "maximum" => 50 },
          "offset" => { "type" => "integer", "minimum" => 0, "maximum" => MAX_RECORDS - 1, "description" => "The next_offset returned by the previous result" }
        } })

      def self.tool_name = "search_records"

      private

      def perform(tool_call:, resource:, query: nil, filters: nil, any: nil, relation_filters: nil, scope: nil, sort: nil, direction: nil, page: 1, offset: nil)
        resource = @session.resource(resource)
        access = @session.access(resource)
        raise AccessDenied, "INVALID_QUERY" unless page.is_a?(Integer) && page.between?(1, 50)
        raise AccessDenied, "INVALID_QUERY" unless sort.nil? || sort.is_a?(String) && sort.match?(Field::NAME)
        raise AccessDenied, "INVALID_QUERY" unless direction.nil? || %w[asc desc].include?(direction)
        offset = (page - 1) * PAGE_LIMIT if offset.nil?
        raise AccessDenied, "INVALID_QUERY" unless offset.is_a?(Integer) && offset.between?(0, MAX_RECORDS - 1)
        result = Queries::List.new(@session.context, resource, assistant: true).call(search: query.presence, page: page.to_s, filters: wire_filters(filters),
          any_filters: wire_any_filters(any), relation_filters: wire_relation_filters(relation_filters),
          scope: list_scope(scope), sort: sort, direction: direction || "asc", page_size: [ PAGE_LIMIT, MAX_RECORDS - offset ].min, offset: offset)
        records, omitted, @row_positions = record_entries_with_positions(access, result.records, :index)
        @queried_count = result.records.size
        payload = { "resource" => resource.key.to_s, "applied_scope" => result.scope,
          "applied_sort" => result.sort ? { "field" => result.sort, "direction" => result.direction } : nil,
          "page" => result.number, "offset" => offset, "has_more" => result.has_next,
          "omitted" => omitted, "records" => records }
        if RailsAiAdmin.configuration.surfaces && @session.chat && tool_call && records.any?
          surface = present_read_view { Assistant.tool_views.present_record_table(context: @session.context, resource: resource,
            ids: records.map { |entry| entry["id"] }, scope: result.scope, query: query.presence, sort: result.sort,
            direction: result.direction, omitted: omitted, chat: @session.chat, call_id: tool_call.id) }
          payload["surface"] = surface.id if surface
        end
        payload
      end

      def record_entries_with_positions(access, records, view)
        resolver = reference_resolver(access)
        access.fields(:read, nil, view: view).select { |field| field.scalar_type == :belongs_to }.each do |field|
          resolver.prime(field, records.filter_map { |record| record.has_attribute?(field.column) ? record.read_attribute(field.column)&.to_s : nil })
        end
        omitted = 0
        positions = []
        entries = []
        records.each_with_index do |record, index|
          entries << record_entry(access, record, view, resolver)
          positions << (index + 1)
        rescue AccessDenied
          omitted += 1
        end
        [ entries, omitted, positions ]
      end

      # Leave room for continuation metadata before applying the byte bound.
      # Advance by SQL rows consumed so omitted pages never loop infinitely.
      def bounded(result)
        return result if result["error"]
        result = super(result.merge("next_offset" => MAX_RECORDS, "limit_reached" => false))
        records = result.fetch("records")
        return failure("UNAVAILABLE") if records.empty? && result["truncated"]
        consumed = result["truncated"] ? @row_positions[records.size - 1].to_i : @queried_count.to_i
        next_offset = result.fetch("offset") + consumed
        more = result["has_more"] || result["truncated"] == true
        result.merge("next_offset" => more && next_offset < MAX_RECORDS ? next_offset : nil,
          "has_more" => more && next_offset < MAX_RECORDS, "limit_reached" => more && next_offset >= MAX_RECORDS)
      end
    end

    # One bounded number, so "how many" never means paging (roadmap
    # "aggregate tools"). Same grants, filters and scope rule as search.
    class CountRecords < Tool
      description "Count one resource's records matching optional text, typed filters and a list scope. " \
        "Every record you may see is counted unless you pass scope. Counts above the cap are reported as capped."
      parameters({ "type" => "object", "required" => [ "resource" ], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "query" => { "type" => "string", "maxLength" => 200 },
          "filters" => { "type" => "object", "description" => "Field name to {operator: value} with operators from describe_resource: eq, in (a list of values), gte, lte, contains (part of the text) or blank (true for empty, false for not empty)",
            "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } },
          "any" => { "type" => "array", "maxItems" => Queries::List::MAX_OR_GROUPS,
            "items" => { "type" => "object", "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } } },
          "relation_filters" => RELATION_FILTERS_SCHEMA,
          "scope" => { "type" => "string", "description" => "Optional scope name from describe_resource" }
        } })

      def self.tool_name = "count_records"

      private

      def perform(tool_call:, resource:, query: nil, filters: nil, any: nil, relation_filters: nil, scope: nil)
        resource = @session.resource(resource)
        result = Queries::List.new(@session.context, resource, assistant: true).count(search: query.presence, filters: wire_filters(filters),
          any_filters: wire_any_filters(any), relation_filters: wire_relation_filters(relation_filters), scope: list_scope(scope))
        { "resource" => resource.key.to_s, "applied_scope" => result.scope, "count" => result.count, "capped" => result.capped }
      end
    end

    # Sums, averages, minimums, maximums and counts, optionally per group, so
    # "what is the total" never means paging. Same grants, filters and scope
    # rule as search; the measured field must be declared aggregatable.
    class AggregateRecords < Tool
      description "Calculate count, sum, average, minimum or maximum over one resource's records, optionally grouped by a " \
        "category field, with the same optional text, typed filters and list scope as search_records. For totals per day, " \
        "week, month or year, pass a group_by_period field as group_by with period; groups are oldest first in the user's " \
        "time zone, weeks start on Monday, and each group is the period's first day. describe_resource lists the " \
        "aggregatable, group_by and group_by_period fields. Every record you may see is included unless you pass scope."
      parameters({ "type" => "object", "required" => %w[resource function], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "function" => { "type" => "string", "enum" => Queries::List::AGGREGATE_FUNCTIONS },
          "field" => { "type" => "string", "description" => "An aggregatable field from describe_resource; omit for count" },
          "group_by" => { "type" => "string", "description" => "Optional group_by field, or a group_by_period field with period" },
          "period_field" => { "type" => "string", "description" => "Optional group_by_period field for a calendar breakdown of each categorical group_by value (up to 25 cells)" },
          "period" => { "type" => "string", "enum" => Queries::List::PERIODS, "description" => "Calendar period for a group_by_period field" },
          "query" => { "type" => "string", "maxLength" => 200 },
          "filters" => { "type" => "object", "description" => "Field name to {operator: value}, as for search_records",
            "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } },
          "any" => { "type" => "array", "maxItems" => Queries::List::MAX_OR_GROUPS,
            "items" => { "type" => "object", "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } } },
          "relation_filters" => RELATION_FILTERS_SCHEMA,
          "scope" => { "type" => "string", "description" => "Optional scope name from describe_resource" }
        } })

      def self.tool_name = "aggregate_records"

      private

      def perform(tool_call:, resource:, function:, field: nil, group_by: nil, period: nil, period_field: nil, query: nil, filters: nil, any: nil, relation_filters: nil, scope: nil)
        resource = @session.resource(resource)
        unless function.is_a?(String) && [ field, group_by, period, period_field ].all? { |value| value.nil? || value.is_a?(String) }
          raise AccessDenied, "INVALID_QUERY"
        end
        result = Queries::List.new(@session.context, resource, assistant: true).aggregate(function: function, field: field, group_by: group_by,
          period: period, period_field: period_field, search: query.presence, filters: wire_filters(filters), any_filters: wire_any_filters(any),
          relation_filters: wire_relation_filters(relation_filters), scope: list_scope(scope))
        references = reference_resolver(@session.access(resource))
        if result.group_by&.scalar_type == :belongs_to
          references.prime(result.group_by, result.groups.filter_map { |group| group.key&.to_s })
        end
        entry = { "resource" => resource.key.to_s, "applied_scope" => result.scope, "function" => function,
          "field" => result.field&.name&.to_s, "count" => result.count }
        entry["value"] = measure(result.field, function, result.value) if result.field
        if result.group_by
          entry["group_by"] = result.group_by.name.to_s
          if result.period
            entry["period_field"] = result.period_field.name.to_s if result.period_field
            entry["period"] = result.period
            entry["time_zone"] = @session.context.time_zone if (result.period_field || result.group_by).scalar_type == :datetime
          end
          entry["groups"] = result.groups.map do |group|
            key = result.period && !result.period_field ? group.key&.iso8601 : typed(result.group_by, group.key, references)
            item = { "group" => key, "count" => group.count }
            item["period_start"] = group.period_start&.iso8601 if result.period_field
            item["value"] = measure(result.field, function, group.value) if result.field
            item
          end
          entry["groups_truncated"] = result.groups_truncated
        end
        if RailsAiAdmin.configuration.surfaces && @session.chat && tool_call
          surface = present_read_view { Assistant.tool_views.present_metric_card(context: @session.context, resource: resource,
            result: result, query: query.presence, filters: wire_filters(filters), any_filters: wire_any_filters(any),
            relation_filters: wire_relation_filters(relation_filters), chat: @session.chat, call_id: tool_call.id) }
          entry["surface"] = surface.id if surface
        end
        entry
      end

      # Exact decimal strings rounded to the field's scale (an average gets two
      # more places); dates and times are ISO 8601.
      def measure(field, function, value)
        return nil if value.nil?
        if function == "average"
          places = (field.scalar_type == :decimal ? field.decimal_limits[:scale].to_i : 0) + 2
          whole, fraction = value.round(places).to_s("F").split(".")
          return "#{whole}.#{fraction.to_s.ljust(places, '0')}"
        end
        case field.scalar_type
        when :integer then value
        when :decimal
          scale = field.decimal_limits[:scale]
          field.format_decimal(scale ? value.round(scale) : value)
        else typed(field, value, nil)
        end
      end
    end

    class GetRecord < Tool
      description "Read one record's fields by resource key and id."
      parameters({ "type" => "object", "required" => %w[resource id], "additionalProperties" => false,
        "properties" => { "resource" => { "type" => "string" }, "id" => { "type" => "string", "maxLength" => 100 } } })

      def self.tool_name = "get_record"

      private

      def perform(tool_call:, resource:, id:)
        resource = @session.resource(resource)
        access = @session.access(resource)
        raise AccessDenied unless id.is_a?(String) && id.match?(Field::REFERENCE)
        record = access.find!(id)
        payload = { "resource" => resource.key.to_s, "records" => [ record_entry(access, record, :show) ] }
        if RailsAiAdmin.configuration.surfaces && @session.chat && tool_call
          surface = present_read_view { Assistant.tool_views.present_record_card(context: @session.context, resource: resource,
            record: record, chat: @session.chat, call_id: tool_call.id) }
          payload["surface"] = surface.id if surface
        end
        payload
      end
    end

    # Prepares a native intent and presents its review Surface. The human's own
    # confirmation in that Surface is the only approval; this tool writes no
    # business data and cannot confirm anything.
    class ProposeOperation < Tool
      description "Propose a change for the user to review. It does not change data: the user confirms or ignores the review shown in the conversation."
      parameters({ "type" => "object", "required" => %w[resource id operation input], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" }, "id" => { "type" => "string", "maxLength" => 100 },
          "operation" => { "type" => "string", "description" => "An operation key from describe_resource" },
          "input" => { "type" => "object", "description" => "Input values for the operation's declared fields" }
        } })

      def self.tool_name = "propose_operation"

      private

      def perform(tool_call:, resource:, id:, operation:, input:)
        raise ConfigurationError, "Surfaces are disabled" unless RailsAiAdmin.configuration.surfaces
        raise ConfigurationError, "A persisted tool call is required" unless tool_call.respond_to?(:id) && tool_call.id.is_a?(String)
        raise AccessDenied, "INVALID_QUERY" unless input.is_a?(Hash) && operation.is_a?(String) && id.is_a?(String)
        resource = @session.resource(resource)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        raise AccessDenied unless definition.custom? && definition.scope == :member && resource.assistant_operation?(definition.key)
        tool_views = Assistant.tool_views
        replay = @session.chat && tool_views.assistant_surface(@session.context, @session.chat, tool_call.id)
        return acknowledgment(replay) if replay
        return failure("LIMIT_REACHED") if @session.tally.full?
        record = @session.access(resource).find!(id, action: definition.key)
        proposal = Operations::Runner.new.preflight(context: @session.context, resource: resource, operation: definition.key,
          target_id: record.id, expected_version: RecordVersion.of(record), input: input, origin: :assistant)
        if proposal.is_a?(Operations::Result)
          return failure(proposal.code == "VALIDATION_FAILED" ? "VALIDATION_FAILED" : proposal.code == "CONFLICT" ? "CONFLICT" : "UNAVAILABLE",
            "fields" => proposal.errors.keys.map(&:to_s))
        end
        surface = present_review(tool_views, resource, definition, record, proposal, tool_call)
        @session.tally.record!
        acknowledgment(surface)
      end
    end

    # Prepares a native create, update or delete intent and presents its
    # review. Nothing changes until the human confirms that review; the write
    # then runs as the human, with a version check, through the shared Runner.
    class ProposeChange < Tool
      ACTIONS = %w[create update destroy].freeze
      # Values a model cannot sensibly supply: secrets and uploads.
      UNSUPPORTED = %i[password file files].freeze
      description "Propose creating, updating or deleting one record. It does not change data: the user reviews and confirms or " \
        "dismisses it in the conversation. For update, send only the fields to change. describe_resource lists the allowed changes."
      parameters({ "type" => "object", "required" => %w[resource action], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "action" => { "type" => "string", "enum" => ACTIONS },
          "id" => { "type" => "string", "maxLength" => 100, "description" => "The record id; required for update and delete" },
          "values" => { "type" => "object", "description" => "Field names and new values, typed as describe_resource reports" }
        } })

      def self.tool_name = "propose_change"

      private

      def perform(tool_call:, resource:, action:, id: nil, values: {})
        raise ConfigurationError, "Surfaces are disabled" unless RailsAiAdmin.configuration.surfaces
        raise ConfigurationError, "A persisted tool call is required" unless tool_call.respond_to?(:id) && tool_call.id.is_a?(String)
        raise AccessDenied, "INVALID_QUERY" unless ACTIONS.include?(action) && values.is_a?(Hash) && (id.nil? || id.is_a?(String))
        raise AccessDenied, "INVALID_QUERY" if action == "create" ? !id.nil? : id.nil?
        raise AccessDenied, "INVALID_QUERY" if action == "destroy" ? values.any? : (action == "update" && values.empty?)
        resource = @session.resource(resource)
        raise AccessDenied unless resource.assistant_change?(action)
        tool_views = Assistant.tool_views
        replay = @session.chat && tool_views.assistant_surface(@session.context, @session.chat, tool_call.id)
        return acknowledgment(replay) if replay
        return failure("LIMIT_REACHED") if @session.tally.full?
        access = @session.access(resource)
        record = action == "create" ? access.relation.new : access.find!(id, action: action.to_sym)
        definition = RailsAiAdmin.operation_registry.fetch(resource, action)
        by_name = resource.fields.index_by { |field| field.name.to_s }
        raise AccessDenied, "INVALID_QUERY" if values.keys.any? { |name| UNSUPPORTED.include?(by_name[name.to_s]&.scalar_type) }
        proposal = Operations::Runner.new.preflight(context: @session.context, resource: resource, operation: action,
          target_id: action == "create" ? nil : record.id, expected_version: action == "create" ? nil : RecordVersion.of(record),
          input: values.transform_keys(&:to_s), origin: :assistant)
        if proposal.is_a?(Operations::Result)
          return failure(proposal.code == "VALIDATION_FAILED" ? "VALIDATION_FAILED" : proposal.code == "CONFLICT" ? "CONFLICT" : "UNAVAILABLE",
            "fields" => proposal.errors.to_h.transform_values { |messages| Array(messages).first(3) })
        end
        surface = present_review(tool_views, resource, definition, record, proposal, tool_call)
        @session.tally.record!
        acknowledgment(surface)
      end
    end

    # Prepares one review that sets the same values on up to 100 records of a
    # fixed selection. Nothing changes until the person confirms that review;
    # each record is then updated as that person, on its own, through the
    # shared Runner (Operations::BulkChange).
    class ProposeBulkChange < Tool
      description "Propose setting the same field values on several records as one review. It does not change " \
        "data: the user reviews the records and confirms or dismisses it. Name up to 100 records with ids, or select them " \
        "with the same query, filters, any, relation_filters and scope as search_records (more than 100 run as a background " \
        "job after confirmation, up to the admin's limit). describe_resource lists bulk_update when it is allowed."
      parameters({ "type" => "object", "required" => %w[resource values], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "values" => { "type" => "object", "description" => "Field names and the new value for every record, typed as describe_resource reports" },
          "ids" => { "type" => "array", "maxItems" => Selections::Builder::LIMIT, "items" => { "type" => "string", "maxLength" => 100 },
            "description" => "Record ids; leave out to use query, filters and scope instead" },
          "query" => { "type" => "string", "maxLength" => 200 },
          "filters" => { "type" => "object", "description" => "Field name to {operator: value}, as for search_records",
            "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } },
          "any" => { "type" => "array", "maxItems" => Queries::List::MAX_OR_GROUPS,
            "items" => { "type" => "object", "additionalProperties" => { "type" => "object", "additionalProperties" => FILTER_VALUE_SCHEMA } } },
          "relation_filters" => RELATION_FILTERS_SCHEMA,
          "scope" => { "type" => "string", "description" => "Optional scope name from describe_resource" }
        } })

      def self.tool_name = "propose_bulk_change"

      private

      def perform(tool_call:, resource:, values:, ids: nil, query: nil, filters: nil, any: nil, relation_filters: nil, scope: nil)
        raise AccessDenied, "INVALID_QUERY" unless values.is_a?(Hash) && values.any? && values.size <= 50
        unless ids.nil? || ids.is_a?(Array) && ids.size.between?(1, Selections::Builder::LIMIT) && ids.all? { |id| id.is_a?(String) && id.match?(Field::REFERENCE) }
          raise AccessDenied, "INVALID_QUERY"
        end
        raise AccessDenied, "INVALID_QUERY" if ids && !(query.nil? && filters.nil? && any.nil? && relation_filters.nil? && scope.nil?)
        resource = @session.resource(resource)
        raise AccessDenied unless resource.assistant_change?(:bulk_update)
        return failure("UNAVAILABLE") unless Operations::BulkChange.available?
        by_name = resource.fields.index_by { |field| field.name.to_s }
        raise AccessDenied, "INVALID_QUERY" if values.keys.any? { |name| ProposeChange::UNSUPPORTED.include?(by_name[name.to_s]&.scalar_type) }
        return failure("LIMIT_REACHED") if @session.tally.full?
        limit = Selections::Builder.async_limit
        target_ids = ids || matching_ids(resource, query, filters, any, relation_filters, scope, limit)
        return failure("TOO_MANY") if target_ids.size > limit
        return failure("NOT_FOUND") if target_ids.empty?
        selection = Selections::Builder.new.capture(context: @session.context, resource: resource, target_ids: target_ids, max_items: limit)
        return failure("NOT_FOUND") if selection.targets.empty?
        values = values.transform_keys(&:to_s)
        access = @session.access(resource)
        model = resource.model_class
        records = access.relation.where(model.primary_key => selection.targets.map(&:id)).index_by { |record| record.id.to_s }
        items, = Operations::BulkChange.review_plan(context: @session.context, resource: resource, selection: selection, records: records, values: values)
        ready = items.count { |item| item.code.nil? }
        if ready.zero?
          code = items.map(&:code).find { |candidate| %w[VALIDATION_FAILED CONFLICT].include?(candidate) } || "NOT_FOUND"
          return failure(code)
        end
        context_ref = @session.chat ? @session.chat.context_reference : @session.conversation
        token = Operations::BulkChange.encode(context: @session.context, selection: selection, resource: resource, values: values, context_ref: context_ref)
        @session.tally.record!
        message = @session.chat ? "One review for #{ready} records is shown to the user. Nothing has changed yet; a later message reports the result." :
          "A review for #{ready} records is waiting in the admin. Nothing has changed until the user opens review_url and confirms it."
        { "status" => "awaiting_human_confirmation", "resource" => resource.key.to_s, "selection" => selection.selection_ref,
          "bulk_change" => token, "records" => ready, "skipped" => items.size - ready, "message" => message }
      end

      # The same records search_records would page through, one past the limit.
      def matching_ids(resource, query, filters, any, relation_filters, scope, limit)
        model = resource.model_class
        Queries::List.new(@session.context, resource, assistant: true).relation(search: query.presence, filters: wire_filters(filters),
          any_filters: wire_any_filters(any), relation_filters: wire_relation_filters(relation_filters), scope: list_scope(scope))
          .limit(limit + 1).pluck(model.arel_table[model.primary_key]).map(&:to_s)
      end
    end

    # A record's audited changes, behind the same view_history? grant as its
    # History page. Field names follow the user's current grants.
    class RecordHistory < Tool
      LIMIT = 20
      description "List the latest audited changes to one record: when, what kind, which fields and by whom. Values are never recorded."
      parameters({ "type" => "object", "required" => %w[resource id], "additionalProperties" => false,
        "properties" => { "resource" => { "type" => "string" }, "id" => { "type" => "string", "maxLength" => 100 } } })

      def self.tool_name = "record_history"

      private

      def perform(tool_call:, resource:, id:)
        resource = @session.resource(resource)
        access = @session.access(resource)
        raise AccessDenied unless id.is_a?(String) && id.match?(Field::REFERENCE)
        record = access.find!(id)
        page = Presentation::History.new(access, record).page
        entries = page.entries.first(LIMIT).map do |entry|
          { "at" => entry.at.in_time_zone(time_zone).iso8601, "change" => entry.operation, "saved" => entry.status == "succeeded",
            "outcome" => entry.code, "fields" => entry.fields, "other_fields" => entry.hidden_fields,
            "by" => entry.actor_ref == @session.context.actor_ref ? "the current user" : entry.actor_ref, "via" => entry.origin }
        end
        { "resource" => resource.key.to_s, "id" => record.id.to_s, "changes" => entries, "more" => page.entries.size > LIMIT || !page.older.nil? }
      end
    end

    TOOLS = [ ListResources, DescribeResource, SearchRecords, CountRecords, AggregateRecords, GetRecord, RecordHistory ].freeze

    # Proposal tools offered with the read tools: single reviews need
    # Surfaces; bulk reviews need a resource that declares bulk_update.
    def self.proposal_tools
      tools = RailsAiAdmin.configuration.surfaces ? [ ProposeOperation, ProposeChange ] : []
      tools << ProposeBulkChange if RailsAiAdmin.registry.resources.any? { |resource| resource.assistant_change?(:bulk_update) }
      tools
    end
  end
end
