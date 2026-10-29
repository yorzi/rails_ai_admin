# frozen_string_literal: true

require "rails/generators"
require "rails/generators/named_base"
require "rails_ai_admin/schema_suggestions"

module RailsAiAdmin
  module Generators
    # Writes an explicit, editable resource without publishing reflected columns.
    class ResourceGenerator < Rails::Generators::NamedBase
      def create_resource
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
        notes = if report.available
          [ "# Schema suggestions only. Review sensitivity, fields and policy before uncommenting.",
            *report.suggestions.map { |suggestion| "# #{suggestion.declaration}" },
            "# #{report.omitted} sensitive, relationship, internal or unsupported columns omitted." ]
        else
          [ "# Schema unavailable. Migrate the model and rerun, or add reviewed scalar fields manually." ]
        end
        create_file target, <<~RUBY
          class #{constant} < RailsAiAdmin::Resource
            model "#{class_name}"
            key :#{key}
            title :id
            readonly
            fields do
              id :id
          #{notes.map { |line| "    #{line}" }.join("\n")}
            end
          end
        RUBY
        say "Review schema suggestions and policies, then add \"#{constant}\" to config.resources. Only readonly ID is enabled."
      end
    end
  end
end
