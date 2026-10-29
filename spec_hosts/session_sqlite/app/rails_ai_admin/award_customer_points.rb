class AwardCustomerPoints < RailsAiAdmin::Operation
  description "Award customer points"
  input { integer :amount, required: true, nullable: false }

  def preflight(_context, customer, input)
    return invalid(:amount) unless input.fetch("amount").between?(1, 1000)
    { points: customer.points.to_i + input.fetch("amount") }
  end

  def perform(_context, customer, input)
    return invalid(:amount) unless input.fetch("amount").between?(1, 1000)
    customer.update!(points: customer.points.to_i + input.fetch("amount"))
    success(customer)
  end
end
