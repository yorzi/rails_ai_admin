# frozen_string_literal: true

# Opt-in admin Chat storage, installed only by `rails_ai_admin:assistant`.
# Chats, messages and turns are Engine-owned. Tool calls and usages live in
# RubyLLM's own shared tables, isolated per chat by their polymorphic message
# and chat columns; they are created here only when the host has none yet.
class CreateRailsAiAdminAssistant < ActiveRecord::Migration[8.1]
  def up
    key = reference_type
    create_ruby_llm_tables(key)

    create_table :rails_ai_admin_assistant_chats, id: key do |t|
      t.string :ref, null: false, limit: 36
      t.string :actor_ref, :tenant_ref, :security_version, null: false, limit: 150
      t.string :title, limit: 120
      t.string :status, null: false, default: "active"
      t.references :ruby_llm_model, type: key, foreign_key: { to_table: :ruby_llm_models }, index: { name: "raa_assistant_chats_model" }
      t.boolean :cancelled, null: false, default: false
      t.timestamps
    end
    add_index :rails_ai_admin_assistant_chats, :ref, unique: true, name: "raa_assistant_chats_ref"
    add_index :rails_ai_admin_assistant_chats, [ :tenant_ref, :actor_ref, :updated_at ], name: "raa_assistant_chats_owner"
    add_check_constraint :rails_ai_admin_assistant_chats, "status IN ('active', 'archived')", name: "raa_assistant_chats_status"

    # Columns follow RubyLLM 2.1.1's message template.
    create_table :rails_ai_admin_assistant_messages, id: key do |t|
      t.references :chat, null: false, type: key, foreign_key: { to_table: :rails_ai_admin_assistant_chats }, index: { name: "raa_assistant_messages_chat" }
      t.string :role, null: false
      t.text :content
      t.boolean :cache_until_here, null: false, default: false
      t.string :cache_ttl
      t.text :thinking_text, :thinking_signature
      t.json :citations, :server_tool_calls, :raw_content, :raw_reasoning
      t.string :finish_reason
      t.timestamps
    end

    # One persistent inbox per chat: human messages and Surface continuations
    # are admitted once by key and run strictly in sequence under a lease.
    create_table :rails_ai_admin_assistant_turns, id: :string, limit: 36 do |t|
      t.references :chat, null: false, type: key, foreign_key: { to_table: :rails_ai_admin_assistant_chats }, index: false
      t.integer :sequence, null: false
      t.string :kind, null: false
      t.string :admission_key, null: false, limit: 100
      t.text :content, null: false
      t.string :status, null: false, default: "queued"
      t.references :user_message, type: key, foreign_key: { to_table: :rails_ai_admin_assistant_messages }, index: { name: "raa_assistant_turns_message" }
      t.string :lease_owner, limit: 36
      t.datetime :lease_expires_at, :next_attempt_at, :completed_at
      t.integer :generation, :attempts, null: false, default: 0
      t.string :error_code, limit: 64
      t.timestamps
    end
    add_index :rails_ai_admin_assistant_turns, [ :chat_id, :sequence ], unique: true, name: "raa_assistant_turns_sequence"
    add_index :rails_ai_admin_assistant_turns, [ :chat_id, :admission_key ], unique: true, name: "raa_assistant_turns_admission"
    add_index :rails_ai_admin_assistant_turns, [ :status, :lease_expires_at ], name: "raa_assistant_turns_due"
    add_check_constraint :rails_ai_admin_assistant_turns, "kind IN ('message', 'continuation')", name: "raa_assistant_turns_kind"
    add_check_constraint :rails_ai_admin_assistant_turns, "status IN ('queued', 'running', 'completed', 'failed', 'cancelled')", name: "raa_assistant_turns_status"
  end

  # RubyLLM's shared tables may belong to the host product; they are kept.
  def down
    drop_table :rails_ai_admin_assistant_turns
    drop_table :rails_ai_admin_assistant_messages
    drop_table :rails_ai_admin_assistant_chats
  end

  private

  # Polymorphic tool-call/usage columns must hold admin message and chat keys,
  # so admin keys follow an existing RubyLLM installation.
  def reference_type
    return :bigint unless table_exists?(:ruby_llm_tool_calls)
    column = connection.columns(:ruby_llm_tool_calls).find { |candidate| candidate.name == "message_id" }
    column&.type == :uuid ? :uuid : :bigint
  end

  # Mirrors the RubyLLM 2.1.1 install template for the tables admin Chat uses.
  def create_ruby_llm_tables(key)
    json = connection.adapter_name.match?(/postg/i) ? :jsonb : :json
    unless table_exists?(:ruby_llm_models)
      create_table :ruby_llm_models, id: key do |t|
        t.string :model_id, :name, :provider, null: false
        t.string :family
        t.datetime :model_created_at
        t.integer :context_window, :max_output_tokens
        t.date :knowledge_cutoff
        t.datetime :unlisted_at
        t.column :modalities, json, default: {}
        t.column :capabilities, json, default: []
        t.column :pricing, json, default: {}
        t.column :metadata, json, default: {}
        t.timestamps
        t.index [ :provider, :model_id ], unique: true
        t.index :provider
        t.index :family
      end
    end
    unless table_exists?(:ruby_llm_tool_calls)
      create_table :ruby_llm_tool_calls, id: key do |t|
        t.references :message, polymorphic: true, null: false, type: key, index: false
        t.references :result, polymorphic: true, type: key, index: false
        t.string :tool_call_id, :name, null: false
        t.text :thought_signature
        t.string :approval
        t.boolean :remote, default: false, null: false
        t.column :arguments, json, default: {}
        t.column :mcp_state, json
        t.column :mcp_result, json
        t.timestamps
        t.index [ :message_type, :message_id ]
        t.index [ :result_type, :result_id ]
        t.index :tool_call_id, unique: true
        t.index :name
      end
    end
    return if table_exists?(:ruby_llm_usages)
    create_table :ruby_llm_usages, id: key do |t|
      t.references :chat, polymorphic: true, type: key, index: false
      t.references :message, polymorphic: true, type: key, index: false
      t.references :owner, polymorphic: true, type: key, index: false
      t.string :operation, :provider, :model, :status, null: false
      t.integer :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :thinking_tokens
      t.column :server_tool_use, json
      t.decimal :input_cost, :output_cost, :cache_read_cost, :cache_write_cost, :thinking_cost, :total_cost, precision: 16, scale: 10
      t.timestamps
      t.index [ :chat_type, :chat_id ]
      t.index [ :message_type, :message_id ]
      t.index [ :owner_type, :owner_id ]
      t.index :status
    end
    entry = ::RubyLLM::Accounting::Usage::Entry
    quote = ->(values) { values.map { |value| connection.quote(value.to_s) }.join(", ") }
    add_check_constraint :ruby_llm_usages, "operation IN (#{quote.call(entry::OPERATIONS)})"
    add_check_constraint :ruby_llm_usages, "status IN (#{quote.call(entry::STATUSES)})"
  end
end
