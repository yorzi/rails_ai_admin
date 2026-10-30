# frozen_string_literal: true

require "rails_ai_admin/templates/catalog"
require "rails_ai_admin/templates/metadata"
require "rails_ai_admin/templates/safe_paths"

module RailsAiAdmin
  module Templates
    class Inspector
      Finding = Data.define(:key, :status, :code, :path, :source_version)
      MAX_FILES = 256
      MAX_ENTRIES = 1024

      def initialize(root:, catalog: Catalog.new, max_files: MAX_FILES, max_entries: MAX_ENTRIES)
        unless max_files.is_a?(Integer) && max_files.between?(1, MAX_FILES) && max_entries.is_a?(Integer) && max_entries.between?(1, MAX_ENTRIES)
          raise ConfigurationError, "Override inspection bounds may only narrow the defaults"
        end
        @root, @catalog = Pathname.new(root).realpath, catalog
        @max_files, @max_entries = max_files, max_entries
      end

      def checks
        @findings, @visited, @files = [], 0, 0
        catch(:limit) do
          %w[rails_ai_admin layouts/rails_ai_admin].each do |namespace|
            path = @root.join("app/views", namespace)
            begin
              SafePaths.check!(@root, path)
              next unless path.exist?
              raise ConfigurationError unless path.directory?
              walk(path)
            rescue ConfigurationError, SystemCallError
              @findings << Finding.new(namespace, :error, "UNSAFE_PATH", "app/views/#{namespace}", nil)
            end
          end
        end
        @findings.sort_by(&:key).freeze
      end

      private

      def walk(directory)
        Dir.each_child(directory) do |name|
          path = directory.join(name)
          @visited += 1
          incomplete! if @visited > @max_entries
          stat = path.lstat
          if stat.directory?
            if @catalog.for_path(path.relative_path_from(@root.join("app/views")).to_s)
              relative = path.relative_path_from(@root).to_s
              @findings << Finding.new(relative, :error, "UNSAFE_PATH", relative, nil)
            else
              walk(path)
            end
          elsif stat.symlink? || !stat.file?
            relative = path.relative_path_from(@root).to_s
            @findings << Finding.new(relative, :error, "UNSAFE_PATH", relative, nil)
          elsif path.basename.to_s.end_with?(".html.erb")
            @files += 1
            incomplete! if @files > @max_files
            @findings << inspect_file(path)
          end
        end
      end

      def incomplete!
        @findings << Finding.new("inventory", :review, "INCOMPLETE", "app/views", nil)
        throw :limit
      end

      def inspect_file(path)
        relative = path.relative_path_from(@root.join("app/views")).to_s
        entry = @catalog.for_path(relative)
        key = entry&.key || relative
        return Finding.new(key, :review, "UNCATALOGED", "app/views/#{relative}", nil) unless entry
        SafePaths.check!(@root, path)
        metadata = Metadata.read(path, entry)
        return Finding.new(key, :review, "UNTRACKED", "app/views/#{relative}", nil) unless metadata
        code, status = if metadata["contract"] != entry.revision
          [ "STALE_CONTRACT", :review ]
        elsif metadata["source_sha256"] != @catalog.source_digest(entry)
          [ "STALE_SOURCE", :review ]
        else
          [ "CURRENT", :ok ]
        end
        Finding.new(key, status, code, "app/views/#{relative}", metadata["gem_version"])
      rescue ConfigurationError, JSON::ParserError
        Finding.new(key, :error, "INVALID_HEADER", "app/views/#{relative}", nil)
      rescue SystemCallError
        Finding.new(key, :error, "UNSAFE_PATH", "app/views/#{relative}", nil)
      end
    end
  end
end
