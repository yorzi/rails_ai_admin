# frozen_string_literal: true

module RailsAiAdmin
  # Stable across processes, but changes when a model's record IDs change meaning.
  module ResourceIdentity
    def self.call(resource)
      model = resource.model_class
      primary_key = model.primary_key
      column = primary_key.is_a?(String) ? model.columns_hash[primary_key] : nil
      { model: resource.model, table: model.table_name, primary_key: primary_key,
        column_type: column&.type, sql_type: column&.sql_type,
        attribute_type: primary_key.is_a?(String) ? model.type_for_attribute(primary_key).type : nil }
    end
  end
end
