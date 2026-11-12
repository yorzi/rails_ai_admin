# frozen_string_literal: true

require "rails/generators/migration"

module RailsAiAdmin
  module Generators
    # Copies each engine migration the host does not have yet. A migration the
    # host already has is kept even with --force: it may have run, and
    # replacing it under a new timestamp would run it twice. Schema changes
    # ship as new migrations.
    # The gem ships no docs/ directory, so generator output links the guides
    # in the source repository (RAA-026).
    GUIDES = "https://github.com/yorzi/rails_ai_admin/blob/main/docs/site"

    module EngineMigrations # :nodoc:
      def self.included(base)
        base.include Rails::Generators::Migration
        base.extend ClassMethods
      end

      module ClassMethods # :nodoc:
        def next_migration_number(dirname)
          [ Time.now.utc.strftime("%Y%m%d%H%M%S"), format("%014d", current_migration_number(dirname) + 1) ].max
        end
      end

      private

      def copy_engine_migrations(directory)
        Engine.root.join(directory).glob("*.rb").sort.each do |source|
          stem = source.basename(".rb").to_s.sub(/\A\d+_/, "")
          existing = self.class.migration_exists?(File.join(destination_root, "db/migrate"), stem)
          if existing
            say_status :exist, Pathname.new(existing).relative_path_from(Pathname.new(destination_root)).to_s, :blue
          else
            migration_template source.to_s, "db/migrate/#{stem}.rb"
          end
        end
      end
    end
  end
end
