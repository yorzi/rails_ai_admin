# frozen_string_literal: true

module RailsAiAdmin
  module Quality
    # Build bounded findings from the policy relation supplied to detect.
    module Checks
      module_function

      def duplicates_by(relation, columns:, normalizer: :exact)
        names = column_names(relation, columns)
        raise ConfigurationError, "Unknown duplicate normalizer" unless %i[exact lower_trim].include?(normalizer)
        table = relation.klass.arel_table
        groups = names.map do |name|
          column = table[name]
          next column if normalizer == :exact
          unless %i[string text].include?(relation.klass.type_for_attribute(name.to_s).type)
            raise ConfigurationError, "lower_trim needs text columns"
          end
          Arel::Nodes::NamedFunction.new("LOWER", [ Arel::Nodes::NamedFunction.new("TRIM", [ column ]) ])
        end
        keys = relation.reorder(nil).group(*groups).having(table[relation.klass.primary_key].count.gt(1))
        groups.each { |group| keys = keys.where(group.not_eq(nil)) }
        keys.order(*groups).limit(100).pluck(*groups).lazy.filter_map do |key|
          matches = groups.zip(Array(key)).reduce(relation) { |rows, (group, value)| rows.where(group.eq(value)) }
          pk = relation.klass.primary_key
          ids = matches.reorder(pk => :asc).limit(Runner::MAX_RECORDS).pluck(pk)
          next if ids.size < 2
          Finding.new(ids.first.to_s, ids, "Matching values", names)
        end
      end

      def blank_fields(relation, fields:)
        names = column_names(relation, fields)
        predicates = names.map do |name|
          column = relation.klass.arel_table[name]
          if %i[string text].include?(relation.klass.type_for_attribute(name.to_s).type)
            column.eq(nil).or(Arel::Nodes::NamedFunction.new("TRIM", [ column ]).eq(""))
          else
            column.eq(nil)
          end
        end
        pk = relation.klass.primary_key
        relation.where(predicates.reduce(&:or)).reorder(pk => :asc).limit(100).pluck(pk).map do |id|
          Finding.new(id.to_s, [ id ], "Missing value", names)
        end
      end

      REFERENCE_SCAN_LIMIT = 1_000

      # Check the first non-null keys under the actor's scope. A missing row,
      # a soft deletion and a target withheld by policy look identical.
      def orphaned_belongs_to(relation, field:, access:, assistant: false)
        declaration = access.resource.fields.find { |entry| entry.name == field && entry.scalar_type == :belongs_to }
        raise ConfigurationError, "Expected a declared belongs_to field" unless declaration && relation.klass == access.resource.model_class
        target = Fields::Association.validate!(access.resource, declaration)
        target_access = Authorization::Access.new(access.context, target)
        target_access.authorize!(:index)
        target_access.authorize_assistant! if assistant
        resolver = Fields::Association.new(access.context, access.resource, assistant: assistant)
        candidates = relation.where.not(declaration.column => nil).reorder(nil).limit(REFERENCE_SCAN_LIMIT)
        Enumerator.new do |results|
          candidates.find_in_batches(batch_size: 100) do |records|
            resolver.prime(declaration, records.map { |record| record[declaration.column] })
            records.each do |record|
              next if resolver.admissible?(declaration, record[declaration.column])
              results << Finding.new(record.id.to_s, [ record.id ], "Referenced record unavailable", [ field ])
            end
          end
        end
      end

      def column_names(relation, names)
        unless names.is_a?(Array) && names.size.between?(1, Runner::MAX_FIELDS) && names.all? { |name| name.is_a?(Symbol) && relation.klass.columns_hash.key?(name.to_s) }
          raise ConfigurationError, "Checks require model column names"
        end
        names
      end
      private_class_method :column_names
    end
  end
end
