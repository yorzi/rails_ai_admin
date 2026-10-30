# frozen_string_literal: true

module RailsAiAdmin
  # Execution bookkeeping; success commits in the target's Runner transaction.
  class BatchItem < ApplicationRecord
    self.table_name = "rails_ai_admin_batch_items"
  end
end
