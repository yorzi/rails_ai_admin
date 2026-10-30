class CustomerStatusSummary < RailsAiAdmin::Fields::Computation
  version "1"
  def call(values, field:, time_zone:)
    "#{values.fetch('active') ? 'Active' : 'Inactive'} · #{values.fetch('points')} points"
  end
end
