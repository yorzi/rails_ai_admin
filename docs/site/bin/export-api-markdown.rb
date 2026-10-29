# frozen_string_literal: true

# Writes a Markdown page for every documented class and module, plus an
# index.md, next to the RDoc HTML. Coding assistants read these.
#   export-api-markdown.rb <output-dir> <source-root> <project-name>

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

output_dir = File.expand_path(ARGV.fetch(0))
source_root = File.expand_path(ARGV.fetch(1))
project = ARGV.fetch(2)
rdoc = [RbConfig.ruby, Gem.bin_path('rdoc', 'rdoc')]
ri = [RbConfig.ruby, Gem.bin_path('rdoc', 'ri')]

def capture!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  abort "#{command.join(' ')} failed\n#{stderr}" unless status.success?

  stdout
end

def clean(markdown, ri_dir)
  markdown
    .gsub(/\s*\(from\s+#{Regexp.escape(ri_dir)}\)/m, '')
    .gsub(%r{<code>(.*?)</code>}m, '`\1`')
    .gsub(/[ \t]+$/, '')
    .gsub(/\n{3,}/, "\n\n")
    .strip
end

FileUtils.mkdir_p(output_dir)

Dir.mktmpdir('api-ri') do |tmp|
  ri_dir = File.join(tmp, 'ri')
  capture!(*rdoc, '--format', 'ri', '--output', ri_dir, '--quiet', 'lib', chdir: source_root)
  options = ['--no-standard-docs', '--doc-dir', ri_dir, '--format', 'markdown', '--width', '1000']
  names = capture!(*ri, *options, '--list', chdir: source_root).lines.map(&:strip).reject(&:empty?).sort

  index = ["# #{project} API Reference", '', '<!-- Generated from RDoc. Do not edit. -->', '',
           "Markdown pages for every public #{project} class and module.", '']
  names.each do |name|
    path = "#{name.gsub('::', '/')}.md"
    destination = File.join(output_dir, path)
    FileUtils.mkdir_p(File.dirname(destination))
    markdown = capture!(*ri, *options, '--all', name, chdir: source_root)
    File.write(destination, "#{clean(markdown, ri_dir)}\n")
    index << "- [#{name}](#{path})"
  end
  File.write(File.join(output_dir, 'index.md'), "#{index.join("\n")}\n")
end
