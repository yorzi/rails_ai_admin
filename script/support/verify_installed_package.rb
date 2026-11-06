# frozen_string_literal: true

require "bundler/setup"
require "rubygems/package"
require "tmpdir"

# Runs in the consumer's bundle. A reused .dev version must still resolve the
# exact package's metadata and bytes, not an old lockfile's copy of its gemspec.
package = Gem::Package.new(ARGV.fetch(0))
expected = package.spec
installed = Gem.loaded_specs.fetch(expected.name)
dependencies = ->(spec) { spec.runtime_dependencies.map { |dependency| [ dependency.name, dependency.requirement.to_s ] }.sort }
unless installed.version == expected.version && dependencies.call(installed) == dependencies.call(expected) &&
    installed.required_ruby_version == expected.required_ruby_version && installed.metadata == expected.metadata
  abort "Installed package metadata differs from the candidate"
end
Dir.mktmpdir("raa-package-identity") do |directory|
  package.extract_files(directory)
  mismatches = expected.files.reject do |path|
    target = File.join(installed.full_gem_path, path)
    File.file?(target) && File.binread(target) == File.binread(File.join(directory, path))
  end
  abort "Installed package files differ from the candidate: #{mismatches.first(5).join(', ')}" if mismatches.any?
end
puts "Installed candidate verified: #{expected.name} #{expected.version}, #{expected.files.size} files; Rails #{Gem.loaded_specs.fetch('rails').version}"
