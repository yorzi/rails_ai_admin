# frozen_string_literal: true

module RailsAiAdmin
  module Assistant
    class ListQualityRules < Tool
      description "List the data quality checks available to this user for one resource."
      parameters({ "type" => "object", "required" => [ "resource" ], "additionalProperties" => false,
        "properties" => { "resource" => { "type" => "string" } } })

      def self.tool_name = "list_quality_rules"

      private

      def perform(tool_call:, resource:)
        access = @session.access(@session.resource(resource))
        rules = RailsAiAdmin.quality_registry.for_access(access)
        { "rules" => rules.map { |rule| { "key" => rule.key.to_s, "description" => rule.description, "severity" => rule.severity.to_s } } }
      end
    end

    class RunQualityRule < Tool
      description "Run a listed read-only data quality check. Returns groups of visible records and their evidence for human review."
      parameters({ "type" => "object", "required" => %w[resource rule], "additionalProperties" => false,
        "properties" => { "resource" => { "type" => "string" }, "rule" => { "type" => "string" } } })

      def self.tool_name = "run_quality_rule"

      private

      def perform(tool_call:, resource:, rule:)
        access = @session.access(@session.resource(resource))
        report = Quality::Runner.new(access, assistant: true).call(rule)
        result = { "rule" => report.rule.key.to_s, "findings" => [], "candidate_limit" => report.rule.max_findings }
        if RailsAiAdmin.configuration.surfaces && @session.chat && tool_call && Quality::MergeReview.merge_rule?(access.resource, report.rule)
          group = report.reviews.find { |entry| entry.rows.size > 1 && entry.rows.all?(&:can_remediate) }
          if group
            surface = present_read_view { Assistant.tool_views.present_merge_review(context: access.context, resource: access.resource,
              rule: report.rule, group: group, chat: @session.chat, call_id: tool_call.id) }
            result["surface"] = surface.id if surface
          end
        end
        report.reviews.each do |review|
          finding = { "summary" => review.summary, "records" => [] }
          result["findings"] << finding
          review.rows.each do |row|
            finding["records"] << { "id" => row.id, "evidence" => row.evidence }
            if JSON.generate(result).bytesize > MAX_RESULT_BYTES - 32
              finding["records"].pop
              result["findings"].pop if finding["records"].empty?
              return result.merge("truncated" => true)
            end
          end
        end
        result
      end
    end
  end
end
