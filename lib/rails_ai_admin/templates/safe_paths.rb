# frozen_string_literal: true

module RailsAiAdmin
  module Templates
    module SafePaths
      # Do not follow existing parent/leaf symlinks, including dangling links.
      # The host root itself is explicitly selected and resolved by its owner.
      def self.check!(root, path)
        requested_root = Pathname.new(root).expand_path
        relative = Pathname.new(path).expand_path.relative_path_from(requested_root)
        root = requested_root.realpath
        raise ConfigurationError, "Override path is outside host root" if relative.each_filename.any? { |part| part == ".." }
        parts = relative.each_filename.to_a
        current = root
        parts.each_with_index do |part, index|
          current = current.join(part)
          begin
            stat = current.lstat
          rescue Errno::ENOENT
            next
          end
          if stat.symlink? || index < parts.size - 1 && !stat.directory?
            raise ConfigurationError, "Override path contains a symlink or invalid parent"
          end
        end
        root.join(relative)
      end
    end
  end
end
