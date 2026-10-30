class BulkAwardCustomerPoints < RailsAiAdmin::Operation
  description "Award points to selected customers"
  lease_duration 5
  execution_window 120
  max_duration 1
  input { integer :amount, required: true, nullable: false }
  def preflight(context, customer, input) = AwardCustomerPoints.new.preflight(context, customer, input)
  def perform(context, customer, input) = AwardCustomerPoints.new.perform(context, customer, input)
end
