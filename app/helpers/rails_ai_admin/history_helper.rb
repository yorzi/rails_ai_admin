# frozen_string_literal: true

module RailsAiAdmin
  module HistoryHelper
    def admin_history_allowed?(resource, record)
      Authorization::Access.new(@context, resource).authorize_history!(record)
    rescue AccessDenied
      false
    end

    def admin_history_time(time)
      local = time.in_time_zone(@context.time_zone)
      tag.time(local.strftime("%-d %b %Y %H:%M:%S %Z"), datetime: local.iso8601)
    end

    # "Updated", "Created", "Deleted" or a custom operation's description,
    # plus the outcome when the change was not saved.
    def admin_history_change(resource, entry)
      name = if %w[create update destroy].include?(entry.operation)
        t(entry.operation, scope: %i[rails_ai_admin history operations])
      else
        RailsAiAdmin.operation_registry.custom(resource).find { |definition| definition.key.to_s == entry.operation }&.description ||
          entry.operation.to_s.humanize
      end
      return name if entry.status == "succeeded"
      safe_join([ name, tag.br, tag.span(t("rails_ai_admin.history.not_saved"), class: "raa-danger"), " ", admin_outcome(entry.code) ])
    end

    def admin_history_fields(entry)
      return "—" if entry.fields.empty? && entry.hidden_fields.zero?
      parts = [ entry.fields.join(", ") ]
      parts << t("rails_ai_admin.history.other_fields", count: entry.hidden_fields) if entry.hidden_fields.positive?
      parts.reject(&:blank?).join("; ")
    end
  end
end
