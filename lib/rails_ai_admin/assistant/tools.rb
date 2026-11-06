# frozen_string_literal: true

require "json"

module RailsAiAdmin
  module Assistant
    # Tool state for one claimed turn: the freshly resolved Context, the chat
    # and a fence that stops a worker whose lease was reassigned.
    Session = ::Data.define(:context, :chat, :fence) do
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
      MESSAGES = {
        "NOT_FOUND" => "Not found or not available to this user.",
        "INVALID_QUERY" => "The request was not valid for this resource.",
        "CONFLICT" => "The record changed. Fetch it again before proposing a change.",
        "VALIDATION_FAILED" => "The proposed input is not valid.",
        "UNAVAILABLE" => "This capability is not available."
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

      def text(field, value) = field.format(value, time_zone: @session.context.time_zone).truncate(500)

      def values(access, record, view)
        fields = access.fields(:read, record, view: view).index_by { |field| field.name.to_s }
        access.project(record, view: view).filter_map do |name, value|
          field = fields[name]
          [ name, text(field, value) ] if field
        end.to_h
      end

      def record_entry(access, record, view)
        { "id" => record.id.to_s, "label" => access.record_label(record, view: view), "fields" => values(access, record, view) }
      end
    end

    class ListResources < Tool
      description "List the admin resources this user may ask about. Call this first to learn resource keys."
      parameters({ "type" => "object", "properties" => {}, "additionalProperties" => false })

      def self.tool_name = "list_resources"

      private

      def perform(tool_call:)
        { "resources" => @session.resources.map { |resource| { "key" => resource.key.to_s, "label" => resource.label } } }
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
          "search" => access.fields(:search).map { |field| field.name.to_s },
          "filters" => access.fields(:filter).map { |field| { "field" => field.name.to_s, "operators" => field.filter_operators.map(&:to_s) } }
        }
        result["operations"] = operations(resource, access) if RailsAiAdmin.configuration.surfaces
        result
      end

      def field_entry(field)
        entry = { "name" => field.name.to_s, "label" => field.label, "type" => field.scalar_type.to_s }
        # Operation inputs declare enum values; without them a model can only guess.
        entry["choices"] = field.choice_options.map { |label, value| { "value" => value, "label" => label } } if %i[select enum].include?(field.scalar_type)
        entry
      end

      # Declared contracts only. Member grants depend on the record, so each
      # proposal is authorized against its record by propose_operation.
      def operations(resource, _access)
        RailsAiAdmin.operation_registry.custom(resource).filter_map do |definition|
          next unless definition.scope == :member && resource.assistant_operation?(definition.key)
          { "key" => definition.key.to_s, "description" => definition.description.to_s.truncate(200),
            "input" => definition.handler_class.input.map { |field| field_entry(field).merge("required" => field.options[:required] == true) } }
        end
      end
    end

    class SearchRecords < Tool
      PAGE_LIMIT = 20
      MAX_RECORDS = 1_000
      description "Search one resource's records with optional text and typed filters. Returns up to 20 records. When has_more is true, pass next_offset as offset to continue, including after truncation."
      parameters({ "type" => "object", "required" => [ "resource" ], "additionalProperties" => false,
        "properties" => {
          "resource" => { "type" => "string" },
          "query" => { "type" => "string", "maxLength" => 200, "description" => "Text matched against searchable fields" },
          "filters" => { "type" => "object", "description" => "Field name to {\"eq\"|\"gte\"|\"lte\": value}",
            "additionalProperties" => { "type" => "object", "additionalProperties" => { "type" => %w[string number boolean] } } },
          "page" => { "type" => "integer", "minimum" => 1, "maximum" => 50 },
          "offset" => { "type" => "integer", "minimum" => 0, "maximum" => MAX_RECORDS - 1, "description" => "The next_offset returned by the previous result" }
        } })

      def self.tool_name = "search_records"

      private

      def perform(tool_call:, resource:, query: nil, filters: nil, page: 1, offset: nil)
        resource = @session.resource(resource)
        access = @session.access(resource)
        raise AccessDenied, "INVALID_QUERY" unless page.is_a?(Integer) && page.between?(1, 50)
        offset = (page - 1) * PAGE_LIMIT if offset.nil?
        raise AccessDenied, "INVALID_QUERY" unless offset.is_a?(Integer) && offset.between?(0, MAX_RECORDS - 1)
        result = Queries::List.new(@session.context, resource).call(search: query.presence, page: page.to_s, filters: wire_filters(filters),
          page_size: [ PAGE_LIMIT, MAX_RECORDS - offset ].min, offset: offset)
        { "resource" => resource.key.to_s, "page" => result.number, "offset" => offset, "has_more" => result.has_next,
          "records" => result.records.map { |record| record_entry(access, record, :index) } }
      end

      # Leave room for continuation metadata before applying the byte bound.
      # Advance by what the model actually saw, not the number queried.
      def bounded(result)
        return result if result["error"]
        result = super(result.merge("next_offset" => MAX_RECORDS, "limit_reached" => false))
        records = result.fetch("records")
        return failure("UNAVAILABLE") if records.empty? && result["truncated"]
        next_offset = result.fetch("offset") + records.size
        more = result["has_more"] || result["truncated"] == true
        result.merge("next_offset" => more && next_offset < MAX_RECORDS ? next_offset : nil,
          "has_more" => more && next_offset < MAX_RECORDS, "limit_reached" => more && next_offset >= MAX_RECORDS)
      end

      def wire_filters(filters)
        return nil if filters.nil? || filters == {}
        raise AccessDenied, "INVALID_QUERY" unless filters.is_a?(Hash) && filters.size <= Queries::List::MAX_FILTER_CONDITIONS
        filters.to_h do |name, conditions|
          raise AccessDenied, "INVALID_QUERY" unless conditions.is_a?(Hash)
          [ name.to_s, conditions.to_h { |operator, value| [ operator.to_s, scalar(value) ] } ]
        end
      end

      def scalar(value)
        case value
        when String then value
        when Integer, Float, true, false then value.to_s
        else raise AccessDenied, "INVALID_QUERY"
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
        { "resource" => resource.key.to_s, "records" => [ record_entry(access, access.find!(id), :show) ] }
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
        replay = tool_views.assistant_surface(@session.context, @session.chat, tool_call.id)
        return acknowledgment(replay) if replay
        record = @session.access(resource).find!(id, action: definition.key)
        proposal = Operations::Runner.new.preflight(context: @session.context, resource: resource, operation: definition.key,
          target_id: record.id, expected_version: record.lock_version, input: input, origin: :assistant)
        if proposal.is_a?(Operations::Result)
          return failure(proposal.code == "VALIDATION_FAILED" ? "VALIDATION_FAILED" : proposal.code == "CONFLICT" ? "CONFLICT" : "UNAVAILABLE",
            "fields" => proposal.errors.keys.map(&:to_s))
        end
        surface = tool_views.present(context: @session.context, resource: resource, definition: definition, record: record,
          intent_ref: proposal.intent.id, input: tool_views.wire_input(proposal.values), chat: @session.chat, call_id: tool_call.id)
        acknowledgment(surface)
      end

      def acknowledgment(surface)
        { "status" => "awaiting_human_confirmation", "surface" => surface.id,
          "message" => "A review is shown to the user. Nothing has changed yet; a later message reports the confirmed result." }
      end
    end

    TOOLS = [ ListResources, DescribeResource, SearchRecords, GetRecord ].freeze
  end
end
