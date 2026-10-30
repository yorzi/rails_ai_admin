class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :account, null: false, foreign_key: true
      t.string :number, null: false
      t.string :state, null: false, default: "draft"
      t.decimal :total, precision: 12, scale: 2, null: false, default: 0
      t.date :delivery_on
      t.boolean :expedited, null: false, default: false
      t.text :review_note
      t.datetime :reviewed_at
      t.string :secret_payment_token
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :orders, [ :account_id, :number ], unique: true
  end
end
