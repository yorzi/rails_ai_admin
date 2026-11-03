# frozen_string_literal: true

require "json"

module RailsAiAdmin
  module Assistant
    # Display entries for one chat, rebuilt per request. Stored tool output is
    # never shown as is: record references are re-read through current grants
    # and Surfaces are restored through the admin scope and policy.
    class Transcript
      MESSAGE_LIMIT = 200
      LINK_LIMIT = 20
      Entry = ::Data.define(:kind, :text, :links, :surface_id, :at)
      Link = ::Data.define(:resource_key, :id, :label)
      ACTIVITY = {
        "list_resources" => "Listed the available resources",
        "describe_resource" => "Read the fields of %<resource>s",
        "search_records" => "Searched %<resource>s",
        "get_record" => "Opened a record in %<resource>s",
        "propose_operation" => "Prepared a review in %<resource>s"
      }.freeze

      def initialize(context, chat)
        @context, @chat = context, chat
      end

      def entries
        continuation_ids = @chat.turns.where(kind: "continuation").where.not(user_message_id: nil).pluck(:user_message_id).to_set
        messages = @chat.messages.where.not(role: "system").includes(:ruby_llm_tool_calls, :ruby_llm_parent_tool_call)
          .reorder(id: :desc).limit(MESSAGE_LIMIT).to_a.reverse
        persisted = messages.flat_map do |message|
          case message.role
          when "user"
            [ entry(continuation_ids.include?(message.id) ? :continuation : :user, message.content, message) ]
          when "assistant"
            activity = message.ruby_llm_tool_calls.map { |call| entry(:activity, activity_text(call), message) }
            message.content.present? ? activity + [ entry(:assistant, message.content, message) ] : activity
          when "tool" then tool_entries(message)
          else []
          end
        end
        persisted + waiting
      end

      private

      # Saved turns whose human text the worker has not added to the chat yet,
      # so a sent message shows at once instead of after the provider call.
      def waiting
        @chat.turns.where(status: Turn::ACTIVE, user_message_id: nil).reorder(:sequence).map do |turn|
          Entry.new(turn.kind == "continuation" ? :continuation : :user, turn.content, [], nil, turn.created_at)
        end
      end

      def entry(kind, text, message, links: [], surface_id: nil)
        Entry.new(kind, text.to_s, links, surface_id, message.created_at)
      end

      def activity_text(call)
        template = ACTIVITY.fetch(call.name) { return "Used a tool" }
        format(template, resource: resource_label(call.arguments.is_a?(Hash) ? call.arguments["resource"] : nil))
      end

      def resource_label(key)
        resource = exposed(key)
        resource ? resource.label : "a resource"
      end

      def exposed(key)
        return unless key.is_a?(String)
        resource = RailsAiAdmin.registry.fetch(key)
        Authorization::Access.new(@context, resource).authorize_assistant!
        resource
      rescue AccessDenied, ConfigurationError, KeyError
        nil
      end

      def tool_entries(message)
        data = JSON.parse(message.content.to_s)
        return [] unless data.is_a?(Hash)
        if data["surface"].is_a?(String) && message.ruby_llm_parent_tool_call&.name == "propose_operation"
          return [ entry(:surface, nil, message, surface_id: data["surface"]) ]
        end
        links = record_links(data["resource"], data["records"])
        links.empty? ? [] : [ entry(:records, nil, message, links: links) ]
      rescue JSON::ParserError
        []
      end

      # Only records the actor can still see, labelled through current grants.
      def record_links(key, records)
        resource = exposed(key)
        return [] unless resource && records.is_a?(Array)
        ids = records.first(LINK_LIMIT).filter_map { |record| record["id"] if record.is_a?(Hash) && record["id"].is_a?(String) }
        return [] if ids.empty?
        access = Authorization::Access.new(@context, resource)
        found = access.relation.where(resource.model_class.primary_key => ids).index_by { |record| record.id.to_s }
        ids.filter_map do |id|
          record = found[id]
          next unless record
          access.authorize!(:show, record)
          Link.new(resource.key.to_s, id, access.record_label(record))
        rescue AccessDenied
          nil
        end
      end
    end
  end
end
