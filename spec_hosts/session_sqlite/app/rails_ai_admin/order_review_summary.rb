class OrderReviewSummary < RailsAiAdmin::Fields::Computation
  version "1"
  def call(values, **)
    "#{values.fetch('number')} · #{values.fetch('state')} · #{values.fetch('total').to_s('F')}"
  end
end
