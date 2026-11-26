# frozen_string_literal: true

module RailsAiAdmin
  class SavedQuery < ApplicationRecord
    self.table_name = "rails_ai_admin_saved_queries"

    def self.visible(context)
      tenant = where(tenant_ref: context.tenant_ref)
      tenant.where(actor_ref: context.actor_ref).or(tenant.where(shared: true))
    end

    def owned_by?(context)
      tenant_ref == context.tenant_ref && actor_ref == context.actor_ref
    end
  end
end
