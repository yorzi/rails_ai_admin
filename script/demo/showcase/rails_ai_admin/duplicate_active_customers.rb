# frozen_string_literal: true

class DuplicateActiveCustomers < RailsAiAdmin::QualityRule
  key :duplicate_active_customers
  resource :customers
  description "Active customers with the same name"
  remediation_operation :combine_customers

  def detect(_context, relation)
    RailsAiAdmin::Quality::Checks.duplicates_by(relation.where(active: true), columns: [ :name, :active ])
  end
end
