# frozen_string_literal: true

require File.expand_path("config/environment", Dir.pwd)
require "rails/generators"
require "rails_ai_admin/templates/inspector"
require "digest"

raise "Only run in a copied packaged test host" unless Rails.env.test? && Rails.root.to_s.include?("/tmp/packaged-")
raise "Use the installed gem" unless Gem.loaded_specs.fetch("rails_ai_admin").full_gem_path.include?("/gems/rails_ai_admin-")
Rails.application.load_generators
catalog = RailsAiAdmin::Templates::Catalog.new
manifest_path = Rails.root.join("tmp/admin_override_probe.json")
mode = ARGV.fetch(0)

case mode
when "prepare"
  raise "Restore the existing override probe first" if manifest_path.exist?
  manifest = {}
  catalog.entries.each do |entry|
    raise "Probe would touch an existing host file" if Rails.root.join("app/views", entry.path).exist?
  end
  manifest_path.dirname.mkpath
  manifest_path.write(JSON.generate(manifest))
  Rails.root.join("tmp/admin_override_rendered.json").delete if Rails.root.join("tmp/admin_override_rendered.json").exist?
  catalog.entries.each do |entry|
    Rails::Generators.invoke("rails_ai_admin:override", [ entry.key ], destination_root: Rails.root.to_s)
    path = Rails.root.join("app/views", entry.path)
    header, *lines = path.read.lines
    body = lines.join
    body = if %w[layout status_layout].include?(entry.key)
      body.sub('<body class="raa"', %(<body class="raa" data-raa-override="#{entry.key}"))
    else
      %(<span data-raa-override="#{entry.key}"></span>\n#{body})
    end
    path.write(header + body)
    manifest[entry.path] = Digest::SHA256.file(path).hexdigest
    manifest_path.write(JSON.generate(manifest))
    Rails::Generators.invoke("rails_ai_admin:override", [ entry.key, "--force" ], destination_root: Rails.root.to_s)
    raise "Generator replaced a reviewed override" unless Digest::SHA256.file(path).hexdigest == manifest.fetch(entry.path)
  end
  puts "Prepared #{manifest.size} explicit public-template overrides; reruns preserved every edit"
when "verify"
  manifest = JSON.parse(manifest_path.read)
  raise "Incomplete override fixture" unless manifest.size == catalog.entries.size
  checks = RailsAiAdmin::Templates::Inspector.new(root: Rails.root).checks
  raise "Override metadata did not remain current" unless checks.size == catalog.entries.size && checks.all? { |check| check.status == :ok && check.code == "CURRENT" }
  manifest.each do |relative, digest|
    raise "Acceptance modified an override unexpectedly" unless Digest::SHA256.file(Rails.root.join("app/views", relative)).hexdigest == digest
  end
  rendered = JSON.parse(Rails.root.join("tmp/admin_override_rendered.json").read)
  puts "Actually rendered host override keys: #{rendered.join(', ')}"
  raise "A public template was not rendered in this host's HTTP acceptance" unless (catalog.entries.map(&:key) - rendered).empty? if ENV["RAA_REQUIRE_ALL_OVERRIDE_TEMPLATES"] == "1"
  puts "All #{checks.size} override source/context headers remain current after host HTTP acceptance"
when "restore"
  if manifest_path.exist?
    manifest = JSON.parse(manifest_path.read)
    failures = []
    manifest.each do |relative, digest|
      entry = catalog.entries.find { |candidate| candidate.path == relative }
      raise "Unknown fixture path" unless entry
      path = Rails.root.join("app/views", entry.path)
      if path.file? && Digest::SHA256.file(path).hexdigest == digest
        path.delete
      else
        failures << entry.key
      end
    end
    raise "Changed fixture files were preserved; inspect override probe manifest" if failures.any?
    manifest_path.delete
    Rails.root.join("tmp/admin_override_rendered.json").delete if Rails.root.join("tmp/admin_override_rendered.json").exist?
  end
  puts "Temporary template overrides removed; host files preserved"
else
  raise "Use prepare, verify or restore"
end
