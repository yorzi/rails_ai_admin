# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Builds readonly has_many panels for one parent record. Children come only
    # from the child resource's current policy relation, narrowed by the child's
    # own belongs_to column; nothing here writes or widens a grant.
    module AssociationPanel
      MAX_PANELS = 10
      MAX_LIMIT = 50
      NAME = /\A[a-z][a-z0-9_]*\z/
      Row = Data.define(:id, :label, :linked)
      # list_filter is the canonical list filter for "view all", present only
      # while the child's reference field carries a current filter grant.
      # list_params is the complete list state for that link: like the panel,
      # it shows every child, not the child's default list tab (RAA-006).
      # unscoped_list is true when the child has a granted default list tab.
      # new_prefill is the prefill for the child's new form when the actor may
      # create a child with a writable reference back to this record.
      Panel = Data.define(:name, :label, :resource_key, :rows, :more, :list_filter, :unscoped_list, :single, :new_prefill) do
        def list_params
          return unless list_filter
          unscoped_list ? { filter: list_filter, scope: Queries::NamedScope::NONE } : { filter: list_filter }
        end
      end

      Definition = Data.define(:name, :resource, :explicit_via, :label, :limit, :single) do
        def self.build(name, resource:, via:, label:, limit:, single: false)
          names = [ name, resource ] + (via.nil? ? [] : [ via ])
          unless names.all? { |value| (value.is_a?(Symbol) || value.is_a?(String)) && value.to_s.match?(NAME) && value.to_s.length <= 100 } &&
              (label.nil? || label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 80)) &&
              limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)
            raise ConfigurationError, "has_many needs stable names, an optional short plain label and a limit of 1..#{MAX_LIMIT}"
          end
          new(name.to_sym, resource.to_sym, via&.to_sym, label&.dup&.freeze, single ? 1 : limit, single)
        end

        # Defaults to the parent model's underscored name, as Rails does.
        def via(parent) = explicit_via || parent.model.to_s.demodulize.underscore.to_sym
        def caption = label || name.to_s.humanize
      end

      class << self
        def build(context, parent, record)
          parent.has_many_declarations.filter_map { |definition| panel(context, parent, record, definition) }
        end

        private

        def panel(context, parent, record, definition)
          child = RailsAiAdmin.registry.fetch(definition.resource)
          access = Authorization::Access.new(context, child)
          access.authorize!(:index)
          field = child.fields.find { |candidate| candidate.name == definition.via(parent) }
          target = Fields::Association.validate!(child, field)
          unless target.model_class == parent.model_class
            raise ConfigurationError, "has_many #{definition.name} must point back to the #{parent.key} model"
          end
          # Listing children by parent reveals each child's reference value.
          return unless access.fields(:read, view: :index).include?(field)
          model = child.model_class
          records = access.relation.where(field.column => record.id)
            .reorder(model.arel_table[model.primary_key].asc).limit(definition.limit + 1).to_a
          rows = records.first(definition.limit).map do |child_record|
            linked = begin
              access.authorize!(:show, child_record)
            rescue AccessDenied
              false
            end
            Row.new(child_record.id.to_s.freeze, access.record_label(child_record, view: :index).freeze, linked)
          end
          filter = access.fields(:filter).include?(field) ? { field.name.to_s => { "eq" => record.id.to_s } }.freeze : nil
          Panel.new(definition.name, definition.caption, child.key, rows.freeze, records.size > definition.limit, filter,
            access.named_scopes.any?(&:default?), definition.single, creatable(access, field, record))
        rescue AccessDenied
          nil
        end

        def creatable(access, field, record)
          child = access.relation.new
          access.authorize!(:create, child)
          return unless access.fields(:write, child, operation: :create).include?(field)
          { field.name.to_s => record.id.to_s }.freeze
        rescue AccessDenied
          nil
        end
      end
    end
  end
end
