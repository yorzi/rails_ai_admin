# frozen_string_literal: true

# Streaming replies keep the text of the request in progress on its turn, and
# MCP clients authenticate with personal access tokens. Steps already present
# are skipped.
class AddStreamingAndAccessTokensToRailsAiAdminAssistant < ActiveRecord::Migration[8.0]
  def up
    add_column :rails_ai_admin_assistant_turns, :draft, :text unless column_exists?(:rails_ai_admin_assistant_turns, :draft)
    return if table_exists?(:rails_ai_admin_access_tokens)
    create_table :rails_ai_admin_access_tokens, id: :string, limit: 36 do |t|
      t.string :actor_ref, :tenant_ref, null: false, limit: 150
      t.string :security_version, null: false, limit: 150
      t.string :name, null: false, limit: 80
      # SHA-256 of the token; the token itself is shown once and never stored.
      t.string :token_digest, null: false, limit: 64
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :rails_ai_admin_access_tokens, :token_digest, unique: true, name: "raa_access_tokens_digest"
    add_index :rails_ai_admin_access_tokens, [ :actor_ref, :tenant_ref ], name: "raa_access_tokens_owner"
  end

  def down
    drop_table :rails_ai_admin_access_tokens, if_exists: true
    remove_column :rails_ai_admin_assistant_turns, :draft, if_exists: true
  end
end
