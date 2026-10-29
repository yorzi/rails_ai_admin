#!/usr/bin/env ruby
# frozen_string_literal: true

# Fills in the version selector for one build: the release numbers, the base
# path, which entry is current, and one entry per archived major version.
#   prepare_versions.rb <versions.yml> <stable|next|vN> <base-path> <release-tag> [archive-tag ...]
#
# It also records `release` (the version this build documents, which
# _plugins/versioned_docs.rb puts in site.version) and `base` (the site's
# base path without the version prefix).

require 'yaml'

path, current, base, release, *archives = ARGV
abort 'usage: prepare_versions.rb <versions.yml> <channel> <base-path> <release-tag> [archive-tag ...]' unless release

number = ->(tag) { tag.delete_prefix('v') }
major = ->(tag) { number.call(tag).split('.').first }

versions = YAML.load_file(path)
items = versions.fetch('items')
items.reject! { |item| item['archive'] }
position = items.index { |item| item['external'] } || items.size
archives.each_with_index do |tag, offset|
  items.insert(position + offset,
               { 'id' => "v#{major.call(tag)}", 'title' => number.call(tag), 'url' => "/v#{major.call(tag)}/",
                 'archive' => true })
end

items.each do |item|
  item['title'] = "#{number.call(release)} (stable)" if item['id'] == 'stable'
  item['url'] = "#{base}#{item.fetch('url')}" unless item['external']
end

entry = items.find { |item| item['id'] == current } or abort "no version entry with id #{current}"
documented = archives.find { |tag| "v#{major.call(tag)}" == current } || release
versions['current'] = entry.fetch('title')
versions['release'] = number.call(documented)
versions['base'] = base
File.write(path, YAML.dump(versions))
