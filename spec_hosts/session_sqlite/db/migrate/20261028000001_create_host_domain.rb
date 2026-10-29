class CreateHostDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
    end
    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.string :email, :password_digest, :role, null: false
      t.integer :security_version, default: 1, null: false
    end
    add_index :users, :email, unique: true
    create_table :customers do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :secret
      t.boolean :active, default: true
      t.integer :points, default: 0
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
  end
end
