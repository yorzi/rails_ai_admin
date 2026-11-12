# frozen_string_literal: true

require "rails/generators"
require "rails/generators/named_base"
require "rails_ai_admin/schema_suggestions"

module RailsAiAdmin
  module Generators
    # Writes an explicit, editable resource without publishing reflected columns.
    class ResourceGenerator < Rails::Generators::NamedBase
      FIELD = /\A([a-z][a-z0-9_]*)(?::([a-z_]+))?\z/

      class_option :fields, type: :array, default: [], banner: "name[:type] ...",
        desc: "Enable these schema-suggested fields; the rest stay commented"

      def create_resource
        requested = requested_fields
        constant = "#{class_name}Admin"
        unless constant.match?(/\A[A-Z][a-zA-Z0-9]*Admin\z/)
          raise Rails::Generators::Error, "Use an unnamespaced model name for this generator"
        end
        key = plural_file_name
        if Registry::RESERVED.include?(key)
          raise Rails::Generators::Error, "Reserved resource key #{key}"
        end
        target = "app/rails_ai_admin/#{file_name}_admin.rb"
        if Object.const_defined?(constant) && !File.exist?(File.join(destination_root, target))
          raise Rails::Generators::Error, "Constant #{constant} already exists"
        end
        report = SchemaSuggestions.new(class_name.safe_constantize).call
        enabled = enabled_suggestions(report, requested)
        rest = report.suggestions - enabled
        notes = if report.available
          [ *(rest.any? ? [ "# Schema suggestions only. Review sensitivity, fields and policy before uncommenting." ] : []),
            *rest.map { |suggestion| "# #{suggestion.declaration}" },
            "# #{report.omitted} sensitive, relationship, internal or unsupported columns omitted." ]
        else
          [ "# Schema unavailable. Migrate the model and rerun, or add reviewed scalar fields manually." ]
        end
        title = enabled.find { |suggestion| suggestion.type == :text }&.name || "id"
        create_file target, <<~RUBY
          class #{constant} < RailsAiAdmin::Resource
            model "#{class_name}"
            key :#{key}
            title :#{title}
            readonly
            fields do
              id :id
          #{[ *enabled.map(&:declaration), *notes ].map { |line| "    #{line}" }.join("\n")}
            end
          end
        RUBY
        fields = [ "id", *enabled.map(&:name) ]
        say "Enabled readonly fields: #{fields.join(', ')}. Grant them in the policy's readable fields, then add \"#{constant}\" to config.resources."
      end

      private

      # name or name:type tokens, in order, without duplicates.
      def requested_fields
        options[:fields].each_with_object({}) do |token, fields|
          match = token.to_s.match(FIELD)
          raise Rails::Generators::Error, "Use name or name:type for --fields, not #{token.inspect}" unless match
          raise Rails::Generators::Error, "#{match[1]} is listed twice in --fields" if fields.key?(match[1])
          fields[match[1]] = match[2]
        end
      end

      # Only fields the schema already suggests can be enabled, so the same
      # sensitivity, relationship and tenant rules apply to --fields.
      def enabled_suggestions(report, requested)
        return [] if requested.empty?
        raise Rails::Generators::Error, "Schema unavailable for #{class_name}; migrate the model before using --fields" unless report.available
        by_name = report.suggestions.index_by(&:name)
        requested.map do |name, type|
          suggestion = by_name[name]
          unless suggestion
            raise Rails::Generators::Error, "#{name} is not a suggested field of #{class_name} (sensitive, relationship, internal, unsupported or missing). Add it by hand after review."
          end
          if type && type != suggestion.type.to_s
            raise Rails::Generators::Error, "#{name} is #{suggestion.type} in the schema, not #{type}"
          end
          suggestion
        end
      end
    end
  end
end
