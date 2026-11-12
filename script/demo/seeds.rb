# Sample data for bin/demo: two tenants, three users and awkward names that
# exercise escaping, Unicode and sorting. The password is for this local demo
# only.
a = Account.create!(name: "Tenant A")
b = Account.create!(name: "Tenant B")
User.create!(account: a, email: "admin@example.test", password: "demo-password", role: "admin")
User.create!(account: a, email: "viewer@example.test", password: "demo-password", role: "viewer")
User.create!(account: b, email: "other@example.test", password: "demo-password", role: "admin")
names = [ "Ada Lovelace", "Grace Hopper", "Zoë Müller", "O'Brien & Sons", "<script>alert(1)</script>", "100% Pure_Co", "李雷", "back\\slash" ]
customers = names.map.with_index { |name, i| Customer.create!(account: a, name: name, points: i * 10, active: i.even?, secret: "never shown #{i}") }
30.times { |i| Customer.create!(account: a, name: format("Bulk Customer %02d", i), points: i) }
Customer.create!(account: b, name: "Other tenant customer")
45.times do |i|
  Order.create!(account: a, number: format("ORD-%04d", i), customer: customers[i % customers.size], total: (i * 13.37).round(2),
    delivery_on: (i % 7 == 0 ? nil : Date.new(2026, 11, 1) + i), expedited: i % 3 == 0, state: %w[draft draft approved rejected][i % 4],
    secret_payment_token: "tok_#{i}")
end
Order.create!(account: b, number: "ORD-B-1", total: 5)
