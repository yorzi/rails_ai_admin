# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Static index table presentation. Columns and the default sort only narrow
    # or order what current read/sort grants already allow; nothing here grants.
    class IndexSettings < Data.define(:columns, :default_sort, :default_direction, :page_size, :count)
      MAX_COLUMNS = 50
      MAX_PAGE_SIZE = 100
      COUNT_STRATEGIES = %i[none exact].freeze
      # Exact counts stop here so a large table never needs a full COUNT(*).
      COUNT_LIMIT = 10_000
      # Short machine-formatted values (IDs, numbers, ISO dates) stay on one line
      # in index cells; hyphens in dates are otherwise legal break points.
      COMPACT_TYPES = %i[id integer decimal date datetime boolean time].freeze
      # Types whose list display is already a link. As the title column they
      # show the record's label instead, linked to the record.
      SELF_LINKING_TYPES = %i[email url belongs_to file files references].freeze

      def initialize(columns: nil, default_sort: nil, default_direction: "asc", page_size: 25, count: :none)
        unless columns.nil? || columns.is_a?(Array) && columns.size.between?(1, MAX_COLUMNS) && columns.all? { |name| name.is_a?(Symbol) } && columns.uniq.size == columns.size
          raise ConfigurationError, "Index columns must be 1 to #{MAX_COLUMNS} distinct field-name symbols"
        end
        raise ConfigurationError, "Index default sort must be a field-name symbol" unless default_sort.nil? || default_sort.is_a?(Symbol)
        raise ConfigurationError, "Index default direction must be asc or desc" unless %w[asc desc].include?(default_direction)
        raise ConfigurationError, "Index page size must be an integer from 1 to #{MAX_PAGE_SIZE}" unless page_size.is_a?(Integer) && page_size.between?(1, MAX_PAGE_SIZE)
        raise ConfigurationError, "Index count must be :none or :exact" unless COUNT_STRATEGIES.include?(count)
        super(columns: columns&.dup&.freeze, default_sort: default_sort, default_direction: String.new(default_direction).freeze, page_size: page_size, count: count)
      end

      # Checks references against the resource's declarations at registration.
      def validate!(fields)
        by_name = fields.index_by(&:name)
        Array(columns).each do |name|
          field = by_name[name]
          unless field && !field.hidden? && field.options[:index]
            raise ConfigurationError, "Index column #{name} must be a declared field visible on index"
          end
        end
        if default_sort
          field = by_name[default_sort]
          raise ConfigurationError, "Index default sort #{default_sort} must be a declared sortable field" unless field && !field.hidden? && !field.virtual? && field.options[:sortable]
        end
        self
      end

      # Orders already-authorized index fields; unlisted fields are omitted.
      def order(fields)
        return fields unless columns
        by_name = fields.index_by(&:name)
        columns.filter_map { |name| by_name[name] }
      end
    end

    # Collects index settings without consulting the database at boot.
    class IndexBuilder
      attr_reader :options

      def initialize
        @options = {}
      end

      def columns(*names) = set(:columns, names.flatten)
      def page_size(value) = set(:page_size, value)
      def count(value) = set(:count, value)

      def default_sort(name, direction = :asc)
        set(:default_sort, name)
        @options[:default_direction] = direction.to_s
      end

      private

      def set(key, value)
        raise ConfigurationError, "Index #{key} is declared twice" if @options.key?(key)
        @options[key] = value
      end
    end
  end
end
