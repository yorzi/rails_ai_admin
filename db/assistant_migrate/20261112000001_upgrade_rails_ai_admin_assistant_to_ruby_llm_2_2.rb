# frozen_string_literal: true

# Adds the storage RubyLLM 2.2 reads and writes, following its
# upgrade_ruby_llm_to_2_2 template. Every step is skipped when already present,
# so it is safe beside a host that ran RubyLLM's own install or upgrade for the
# shared tables (tool calls, usages, queued messages, chat files).
class UpgradeRailsAiAdminAssistantToRubyLlm22 < ActiveRecord::Migration[8.0]
  CHATS = :rails_ai_admin_assistant_chats
  MESSAGES = :rails_ai_admin_assistant_messages

  def up
    add_column CHATS, :claim_token, :string unless column_exists?(CHATS, :claim_token)
    add_column CHATS, :claimed_until, :datetime unless column_exists?(CHATS, :claimed_until)
    unless index_exists?(CHATS, :claimed_until, name: "raa_assistant_chats_claim")
      add_index CHATS, :claimed_until, where: "claim_token IS NOT NULL", name: "raa_assistant_chats_claim"
    end
    add_column MESSAGES, :phase, :string unless column_exists?(MESSAGES, :phase)
    add_column MESSAGES, :continuation, :text unless column_exists?(MESSAGES, :continuation)

    upgrade_tool_calls
    upgrade_usages
    key = reference_type
    create_queued_messages(key)
    create_chat_files(key)
  end

  # RubyLLM's shared tables may belong to the host product; they are kept.
  def down
    remove_index CHATS, name: "raa_assistant_chats_claim", if_exists: true
    remove_column CHATS, :claimed_until, if_exists: true
    remove_column CHATS, :claim_token, if_exists: true
    remove_column MESSAGES, :continuation, if_exists: true
    remove_column MESSAGES, :phase, if_exists: true
  end

  private

  def upgrade_tool_calls
    unless column_exists?(:ruby_llm_tool_calls, :provider_call_id)
      if column_exists?(:ruby_llm_tool_calls, :provider_id)
        rename_column :ruby_llm_tool_calls, :provider_id, :provider_call_id
      else
        add_column :ruby_llm_tool_calls, :provider_call_id, :string
      end
    end
    add_column :ruby_llm_tool_calls, :namespace, :string unless column_exists?(:ruby_llm_tool_calls, :namespace)
    add_column :ruby_llm_tool_calls, :claimed_until, :datetime unless column_exists?(:ruby_llm_tool_calls, :claimed_until)
  end

  # An operation check written by 2.1 lacks code_execution. Admin Chat never
  # runs code, so it is left alone; a host that does runs RubyLLM's upgrade.
  def upgrade_usages
    %i[workflow_id workflow_name workflow_step_id workflow_step_name].each do |column|
      add_column :ruby_llm_usages, column, :string unless column_exists?(:ruby_llm_usages, column)
    end
    add_index :ruby_llm_usages, :workflow_id unless index_exists?(:ruby_llm_usages, :workflow_id)
    add_column :ruby_llm_usages, :characters, :integer unless column_exists?(:ruby_llm_usages, :characters)
    add_column :ruby_llm_usages, :audio_seconds, :decimal, precision: 16, scale: 6 unless column_exists?(:ruby_llm_usages, :audio_seconds)
    add_column :ruby_llm_usages, :search_units, :integer unless column_exists?(:ruby_llm_usages, :search_units)
    %i[characters_cost audio_seconds_cost search_units_cost].each do |column|
      add_column :ruby_llm_usages, column, :decimal, precision: 16, scale: 10 unless column_exists?(:ruby_llm_usages, column)
    end
  end

  def create_queued_messages(key)
    return if table_exists?(:ruby_llm_queued_messages)
    create_table :ruby_llm_queued_messages, id: key do |t|
      t.references :chat, polymorphic: true, null: false, type: key, index: false
      t.references :sender, polymorphic: true, type: key, index: false
      t.text :content
      t.boolean :steer, default: true, null: false
      t.timestamps
      t.index [ :chat_type, :chat_id ]
      t.index [ :sender_type, :sender_id ]
    end
  end

  def create_chat_files(key)
    unless table_exists?(:ruby_llm_chat_files)
      create_table :ruby_llm_chat_files, id: key do |t|
        t.references :chat, polymorphic: true, null: false, type: key, index: false
        t.references :owner, polymorphic: true, type: key, index: false
        t.string :path, null: false
        t.string :content_type
        t.bigint :byte_size
        t.string :digest
        t.text :text
        t.string :read_digest
        t.timestamps
        t.index [ :chat_type, :chat_id, :path ]
        t.index [ :owner_type, :owner_id ]
      end
    end
    add_column :ruby_llm_chat_files, :read_digest, :string unless column_exists?(:ruby_llm_chat_files, :read_digest)
  end

  # New polymorphic columns hold the same keys as the existing tool calls.
  def reference_type
    column = connection.columns(:ruby_llm_tool_calls).find { |candidate| candidate.name == "message_id" }
    column&.type == :uuid ? :uuid : :bigint
  end
end
