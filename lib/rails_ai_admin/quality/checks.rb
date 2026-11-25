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
