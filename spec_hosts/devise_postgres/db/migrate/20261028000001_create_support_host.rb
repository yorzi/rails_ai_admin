class CreateSupportHost < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
    end
    create_table :staff_users do |t|
      t.string :email, null: false
      t.string :encrypted_password, null: false, default: ""
      t.string :role, null: false
      t.integer :security_version, null: false, default: 1
      t.timestamps
    end
    add_index :staff_users, :email, unique: true
    create_table :tenant_memberships do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :staff_user, null: false, foreign_key: true
    end
    add_index :tenant_memberships, [ :tenant_id, :staff_user_id ], unique: true, name: "membership_owner"
    create_table :support_tickets, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :subject, null: false
      t.string :state, null: false, default: "open"
      t.integer :priority, default: 0
      t.text :internal_note
      t.string :secret_token
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
  end
end
