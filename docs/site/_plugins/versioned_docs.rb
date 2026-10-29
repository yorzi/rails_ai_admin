# frozen_string_literal: true

# Runs once per build, after Jekyll reads the site.
#
# - docs_unreleased is true for the /next/ build, and for an unversioned build
#   while _config.yml says `released: false`. Pages use it to show the install
#   command for the default branch. A build of a release tag is never
#   unreleased, even when that tag forgot to set `released: true`.
# - A versioned build takes `version` from _data/versions.yml, which
#   bin/prepare_versions.rb fills in from the tag, so a tag that forgot to bump
#   `version` still shows the right install command.
# - An absolute canonical_url on this site becomes a path, so the theme adds
#   this build's base path (/next/, /v1/) and the page stays in its own
#   build's llms.txt and sitemap.
# - llms.txt names the documented version, and links to the site's /api/
#   point at this build's API reference.
Jekyll::Hooks.register :site, :post_read, priority: :high do |site|
  versions = site.data['versions'].is_a?(Hash) ? site.data['versions'] : {}
  current = versions['current'].to_s
  if current.empty?
    site.config['docs_unreleased'] = site.config['released'] == false
  else
    site.config['docs_unreleased'] = ['next', 'Next (unreleased)'].include?(current)
    release = versions['release'].to_s
    site.config['version'] = release unless release.empty?
  end

  origin = site.config['url'].to_s.delete_suffix('/')
  base = site.config['baseurl'].to_s.delete_suffix('/')
  root = "#{origin}#{versions.fetch('base', base).to_s.delete_suffix('/')}"
  unless origin.empty?
    (site.pages + site.collections.values.flat_map(&:docs)).each do |page|
      canonical = page.data['canonical_url']
      next unless canonical.is_a?(String) && canonical.start_with?("#{root}/")

      page.data['canonical_url'] = canonical.delete_prefix(root)
    end
  end

  llms = site.config.dig('jekyll_vitepress', 'llms')
  next unless llms.is_a?(Hash) && !current.empty?

  label = current == 'next' ? 'Next (unreleased)' : current
  llms['description'] = "Developer documentation for #{site.config['title']} #{label}."
  llms['details'] = llms['details'].to_s.gsub("#{root}/api/", "#{origin}#{base}/api/") unless origin.empty?
end
