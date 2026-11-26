# frozen_string_literal: true

module RailsAiAdmin
  class ImportRow < ApplicationRecord
    self.table_name = "rails_ai_admin_import_rows"

    def input
      ImportDraft.encryptor.decrypt_and_verify(input_blob, purpose: "#{draft_id}/#{number}")
    end
  end
end
