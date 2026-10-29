#!/usr/bin/env ruby
# frozen_string_literal: true

# Gives the RDoc pages the search and social metadata the theme gives the
# guides: a canonical URL, robots, Open Graph and Twitter image tags, and
# JSON-LD. Adds the pages to the build's sitemap.xml, and points links to the
# production site (the .rdoc_options footer) at this build.
#   postprocess_api_seo.rb <api-dir> <_config.yml> <main-page.html>
# SITE_URL is the build's address and ROOT_URL the production site's; both
# default to `url` plus `baseurl` from _config.yml.

require 'cgi'
require 'date'
require 'json'
require 'pathname'
require 'yaml'

output_dir = Pathname(ARGV.fetch(0)).expand_path
config_path = Pathname(ARGV.fetch(1)).expand_path
main_page = ARGV.fetch(2, 'index.html')
config = YAML.safe_load_file(config_path, permitted_classes: [Date, Time], aliases: true) || {}
trim = ->(url) { url.to_s.sub(%r{/+\z}, '') }
configured = "#{trim.call(config['url'])}#{trim.call(config['baseurl'])}"
site_root = trim.call(ENV.fetch('SITE_URL', configured))
production_root = trim.call(ENV.fetch('ROOT_URL', configured))
unless site_root.match?(%r{\Ahttps?://})
  warn 'postprocess_api_seo: url in _config.yml is not an absolute http(s) address; skipping API metadata'
  exit
end

name = config['title'].to_s
description = config['description'].to_s
language = (config['lang'] || 'en-US').to_s
seo = config.dig('jekyll_vitepress', 'seo')
image = seo.is_a?(Hash) ? seo['image'] : nil
image = image['path'] if image.is_a?(Hash)
image ||= '/assets/images/social/index.png' if config_path.dirname.join('_plugins', 'social_cards.rb').file?
image_url = image && (image.to_s.match?(%r{\Ahttps?://}) ? image.to_s : "#{site_root}#{image}")
default_robots = 'index,follow,max-image-preview:large,max-snippet:-1,max-video-preview:-1'
index_pages = ['index.html', main_page].uniq
api_urls = []

def tag(name, attributes)
  rendered = attributes.map { |key, value| %(#{key}="#{CGI.escapeHTML(value)}") }.join(' ')
  "<#{name} #{rendered}>"
end

# Escapes the characters that would let a value close the ld+json block early.
def json_ld(graph)
  JSON.generate(graph).gsub(/[<>&  ]/) { |char| format('\\u%04x', char.ord) }
end

# A link to the production site moves to this build only when this build has
# the page, so a footer that names another base path is left alone.
build_root = output_dir.parent
in_build = lambda do |route|
  route = route.split(/[?#]/).first.to_s
  candidate = build_root.join(route)
  route.empty? || candidate.file? || candidate.join('index.html').file?
end

output_dir.glob('**/*.html').sort.each do |path|
  relative_path = path.relative_path_from(output_dir).to_s
  html = path.read
  unless production_root == site_root
    html = html.gsub(%r{href="#{Regexp.escape(production_root)}/([^"]*)"}) do
      route = Regexp.last_match(1)
      in_build.call(route) ? %(href="#{site_root}/#{route}") : Regexp.last_match(0)
    end
  end
  redirect = html.match?(/<meta[^>]+http-equiv="refresh"/i)
  target = html[/<meta[^>]+http-equiv="refresh"[^>]+url=([^";]+)[^>]*>/i, 1]
  canonical = if index_pages.include?(relative_path)
                "#{site_root}/api/"
              elsif redirect && target
                "#{site_root}/api/#{target}"
              else
                "#{site_root}/api/#{relative_path}"
              end
  title = CGI.unescapeHTML(html[%r{<title>(.*?)</title>}mi, 1].to_s).strip
  page_description = CGI.unescapeHTML(html[/<meta\s+name="description"\s+content="([^"]*)"/mi, 1].to_s).strip

  html = html.sub(/<link\s+rel="canonical"\s+href="[^"]*">/i, '')
  metadata = [
    tag('link', 'rel' => 'canonical', 'href' => canonical),
    tag('meta', 'name' => 'robots', 'content' => redirect ? 'noindex,follow' : default_robots),
    tag('meta', 'property' => 'og:url', 'content' => canonical),
    tag('meta', 'property' => 'og:site_name', 'content' => name)
  ]
  if image_url
    # RDoc writes og:title, og:description, and a summary Twitter card already.
    html = html.sub(/(<meta\s+name="twitter:card"\s+content=")summary(")/i, '\1summary_large_image\2')
    metadata << tag('meta', 'property' => 'og:image', 'content' => image_url)
    metadata << tag('meta', 'property' => 'og:image:alt', 'content' => name)
    metadata << tag('meta', 'name' => 'twitter:image', 'content' => image_url)
  end

  unless redirect
    website_id = "#{site_root}/#website"
    page = {
      '@type' => 'WebPage', '@id' => "#{canonical}#webpage", 'url' => canonical,
      'name' => title, 'description' => page_description,
      'isPartOf' => { '@id' => website_id }, 'inLanguage' => language
    }
    graph = [{
      '@type' => 'WebSite', '@id' => website_id, 'url' => "#{site_root}/",
      'name' => name, 'description' => description, 'inLanguage' => language
    }]
    if image_url
      graph << { '@type' => 'ImageObject', '@id' => "#{image_url}#primaryimage", 'url' => image_url,
                 'contentUrl' => image_url, 'caption' => name }
      page['primaryImageOfPage'] = { '@id' => "#{image_url}#primaryimage" }
    end
    graph << page
    metadata << %(<script type="application/ld+json">#{json_ld({ '@context' => 'https://schema.org', '@graph' => graph })}</script>)
    api_urls << canonical
  end

  html = html.sub(/<head>/i, "<head>\n#{metadata.join("\n")}")
  html = html.sub(/<body\b/i, "</head>\n<body") unless html.match?(%r{</head>}i)
  html = "#{html.rstrip}\n</html>\n" unless html.match?(%r{</html>}i)
  path.write(html)
end

sitemap_path = output_dir.parent.join('sitemap.xml')
if sitemap_path.file? && !api_urls.empty?
  rows = api_urls.uniq.sort.map { |url| "  <url>\n    <loc>#{CGI.escapeHTML(url)}</loc>\n  </url>" }.join("\n")
  sitemap_path.write(sitemap_path.read.sub(%r{</urlset>}, "#{rows}\n</urlset>"))
end
