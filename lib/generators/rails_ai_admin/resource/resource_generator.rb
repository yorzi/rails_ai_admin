# frozen_string_literal: true

require "rails/generators/named_base"

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
        create_file target, <<~RUBY
          class #{constant} < RailsAiAdmin::Resource
            model "#{class_name}"
            key :#{key}
            title :id
            readonly
            fields do
              id :id
              # Add reviewed scalar fields here. Nothing is inferred or exposed.
            end
          end
        RUBY
        say "Add \"#{constant}\" to config.resources after reviewing fields and policies. Writes remain readonly."
      end
    end
  end
end
