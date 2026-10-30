class TicketReviewSummary < RailsAiAdmin::Fields::Computation
  version "1"
  def call(values, field:, time_zone:)
    "#{values.fetch('state')} · P#{values.fetch('priority')} · #{values.fetch('internal_note') || 'No note'}"
  end
end
