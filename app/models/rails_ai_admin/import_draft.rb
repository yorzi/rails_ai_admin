# frozen_string_literal: true

module RailsAiAdmin
  class ImportDraft < ApplicationRecord
    self.table_name = "rails_ai_admin_import_drafts"

    def self.open_for(context)
      where(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, security_version: context.security_version, status: "draft")
        .where("expires_at > ?", Time.current)
    end

    def self.encryptor
      purpose = "rails-ai-admin/import-draft/v1"
      length = ActiveSupport::MessageEncryptor.key_len
      ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key(purpose, length), serializer: JSON)
    end
  end
end
