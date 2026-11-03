class AddCustomerToOrders < ActiveRecord::Migration[8.1]
  def change
    add_reference :orders, :customer, foreign_key: true, null: true
  end
end
