# frozen_string_literal: true

require "rails/generators"
require "rails_ai_admin/templates/catalog"
require "rails_ai_admin/templates/metadata"
require "rails_ai_admin/templates/safe_paths"

module RailsAiAdmin
  module Generators
    # Copies one public template without ever replacing a host-owned file.
    class OverrideGenerator < Rails::Generators::Base
      argument :template_key, type: :string, required: false
      class_option :list, type: :boolean, default: false, desc: "List public keys, target paths and context contracts"

      def create_override
        catalog = Templates::Catalog.new
        if options[:list]
          catalog.entries.each { |entry| say "#{entry.key}: app/views/#{entry.path} (contract #{entry.revision}; locals #{entry.locals.join(',')}; assigns #{entry.assigns.join(',')})" }
          return
        end
        raise Rails::Generators::Error, "Choose one public key; use --list" unless template_key
        entry = catalog.fetch(template_key)
        relative = "app/views/#{entry.path}"
        path = Templates::SafePaths.check!(destination_root, File.join(destination_root, relative))
        raise ConfigurationError if path.exist? && !path.file?
        if behavior == :revoke
          say_status :skip, "Host overrides are preserved; remove the reviewed file manually: #{relative}"
        elsif path.exist?
          say_status :skip, "Existing host override preserved: #{relative}. Run rails_ai_admin:doctor for upgrade metadata."
        elsif options[:pretend]
          say_status :create, relative
        else
          body = Templates::Metadata.line(entry, catalog) + File.binread(catalog.source_path(entry))
          FileUtils.mkdir_p(path.dirname)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.binmode; file.write(body) }
          say_status :create, relative
          say "Review authorization/escaping, CSRF/intent fields and failure paths before changing this trusted Rails template."
        end
      rescue Errno::EEXIST
        say_status :skip, "A host override already exists; nothing was replaced."
      rescue ConfigurationError, SystemCallError
        raise Rails::Generators::Error, "Cannot generate this override safely. Use --list and check standard host view paths. No existing file was replaced."
      end
    end
  end
end
