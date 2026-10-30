# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    module DependencyGraph
      MAX_FIELDS = 128
      MAX_DEPTH = 8
      MAX_DEPENDENCIES = 20

      def self.validate!(fields)
        return unless fields.any?(&:virtual?)
        raise ConfigurationError, "Computed resource exceeds field bound" if fields.size > MAX_FIELDS
        declared = fields.index_by(&:name)
        depths = {}
        visit = lambda do |field, path|
          return 0 unless field.virtual?
          return depths[field.name] if depths.key?(field.name)
          raise ConfigurationError, "Computed dependency cycle" if path.include?(field.name)
          depth = 1 + (field.dependencies.map do |name|
            dependency = declared.fetch(name) { raise ConfigurationError, "Computed dependency must be a declared field" }
            visit.call(dependency, path + [ field.name ])
          end.max || 0)
          raise ConfigurationError, "Computed dependency depth exceeds bound" if depth > MAX_DEPTH
          depths[field.name] = depth
        end
        fields.select(&:virtual?).each { |field| visit.call(field, []) }
      end

      def self.readable(fields)
        granted = fields.index_by(&:name)
        eligible = {}
        visit = lambda do |field, path|
          return eligible[field.name] if eligible.key?(field.name)
          return eligible[field.name] = true unless field.virtual?
          raise ConfigurationError, "Invalid computed dependency graph" if path.include?(field.name) || path.size >= MAX_DEPTH
          eligible[field.name] = field.dependencies.all? do |name|
            dependency = granted[name]
            dependency && visit.call(dependency, path + [ field.name ])
          end
        end
        fields.select { |field| visit.call(field, []) }
      end
    end
  end
end
