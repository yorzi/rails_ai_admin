# Showcase tables for bin/demo --showcase: articles with every everyday field
# type, tags for many-to-many editing and a one-to-one summary.
class CreateShowcase < ActiveRecord::Migration[8.1]
  def change
    create_table :articles do |t|
      t.references :account, null: false
      t.string :title, null: false
      t.integer :views, null: false, default: 0
      t.string :contact
      t.string :website
      t.time :opens_at
      t.json :settings
      t.string :password_digest
      t.datetime :discarded_at, index: true
      t.timestamps
    end
    create_table :tags do |t|
      t.references :account, null: false
      t.string :name, null: false
      t.timestamps
    end
    create_table :taggings do |t|
      t.references :article, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
    end
    create_table :summaries do |t|
      t.references :account, null: false
      t.references :article, null: false, foreign_key: true
      t.string :text, null: false
      t.timestamps
    end
  end
end
