class ReviewOrderOperation < RailsAiAdmin::Operation
  version "1"
  description "Review order"
  input do
    enum :decision, values: %w[approve reject], required: true, nullable: false
    field :note, type: :trimmed_text, required: true, nullable: false, max_length: 120
  end

  def preflight(_context, _order, input)
    { state: input.fetch("decision") == "approve" ? "approved" : "rejected", review_note: input.fetch("note") }
  end

  def perform(_context, order, input)
    return invalid(:note) if input.fetch("note").strip.empty?
    order.update!(state: input.fetch("decision") == "approve" ? "approved" : "rejected",
      review_note: input.fetch("note"), reviewed_at: Time.current)
    success(order)
  end
end
