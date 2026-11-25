# frozen_string_literal: true

class MissingDeliveryDate < RailsAiAdmin::QualityRule
  key :missing_delivery_date
  resource :orders
  description "Orders missing a delivery date"
  remediation_change :update

  def detect(_context, relation)
    RailsAiAdmin::Quality::Checks.blank_fields(relation, fields: [ :delivery_on ])
  end
end
