#!/usr/bin/env ruby
# frozen_string_literal: true

# Ties the versioned builds together once bin/build.sh has assembled them.
# A page that only an archived major version still has gets a redirect at its
# old root URL, so links from before the major release keep working, and
# robots.txt lists the sitemap of every build under the root.
#   link_versions.rb <site-dir> <origin> <base-path> <channel> [channel ...]

require 'cgi'
require 'fileutils'
require 'json'

site, origin, base, *channels = ARGV
abort 'usage: link_versions.rb <site-dir> <origin> <base-path> <channel> [channel ...]' if channels.empty?
site = File.expand_path(site)

def redirect_page(path, target, canonical)
  FileUtils.mkdir_p(File.dirname(path))
  escaped = CGI.escapeHTML(target)
  File.write(path, <<~HTML)
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>This page has moved</title>
      <link rel="canonical" href="#{CGI.escapeHTML(canonical)}">
      <meta name="robots" content="noindex,follow">
      <script>window.location.replace(#{JSON.generate(target)} + window.location.search + window.location.hash);</script>
      <meta http-equiv="refresh" content="0;url=#{escaped}">
    </head>
    <body><p>This page has moved to <a href="#{escaped}">#{escaped}</a>.</p></body>
    </html>
  HTML
end

versioned = channels.map { |channel| "#{channel}/" }
channels.grep(/\Av\d+\z/).each do |archive|
  Dir.glob('**/*.html', base: File.join(site, archive)).sort.each do |relative|
    next if relative == '404.html' || relative.start_with?(*versioned)
    next if File.exist?(File.join(site, relative))

    target = "#{base}/#{archive}/#{relative.delete_suffix('index.html')}"
    redirect_page(File.join(site, relative), target, "#{origin}#{target}")
  end
end

robots = File.join(site, 'robots.txt')
if File.file?(robots) && origin.match?(%r{\Ahttps?://})
  sitemaps = channels.select { |channel| File.file?(File.join(site, channel, 'sitemap.xml')) }
  File.open(robots, 'a') do |file|
    sitemaps.each { |channel| file.puts "Sitemap: #{origin}#{base}/#{channel}/sitemap.xml" }
  end
end
