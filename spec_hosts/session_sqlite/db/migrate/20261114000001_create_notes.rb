class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.references :account, null: false, foreign_key: true
      t.string :body, null: false
      t.datetime :discarded_at, index: true
      t.timestamps
    end
  end
end
