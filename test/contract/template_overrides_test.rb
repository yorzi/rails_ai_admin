# frozen_string_literal: true

require "test_helper"
require "support/application"
require "rails_ai_admin/doctor"
require "rails_ai_admin/templates/catalog"
require "rails_ai_admin/templates/inspector"
require "generators/rails_ai_admin/override/override_generator"
require "tmpdir"

class TemplateOverridesTest < Minitest::Test
  def with_host
    Dir.mktmpdir("raa-overrides-", File.expand_path("../../tmp", __dir__)) { |root| yield Pathname.new(root) }
  end

  def generate(root, key = "resource_index", **options)
    capture_io { RailsAiAdmin::Generators::OverrideGenerator.new([ key ].compact, options, destination_root: root.to_s).invoke_all }
  end

  def inspector(root, **options) = RailsAiAdmin::Templates::Inspector.new(root: root, **options)
  def catalog = RailsAiAdmin::Templates::Catalog.new
  def target(root, key = "resource_index") = root.join("app/views", catalog.fetch(key).path)

  def test_catalog_only_lists_real_public_templates_and_explicit_context
    keys = catalog.entries.map(&:key)
    assert_includes keys, "resource_new"
    assert_includes keys, "resource_edit"
    assert_includes keys, "field_index"
    assert_includes keys, "field_show"
    assert_includes keys, "operation_confirmation"
    assert_includes keys, "collection_confirmation"
    refute_includes keys, "surface"
    catalog.entries.each do |entry|
      assert File.file?(catalog.source_path(entry)), entry.key
      assert entry.frozen?
      assert entry.assigns.frozen?
      assert entry.locals.frozen?
      assert_equal 64, catalog.source_digest(entry).length
    end
    assert_equal %i[field value text], catalog.fetch("field_show").locals
  end

  def test_every_public_template_copies_unicode_bytes_without_transcoding_or_extra_files
    with_host do |root|
      catalog.entries.each do |entry|
        generate(root, entry.key)
        body = target(root, entry.key).binread.split("\n", 2).last
        assert_equal catalog.source_path(entry).binread, body, entry.key
      end
      assert_equal catalog.entries.size, root.glob("**/*").count(&:file?)
      assert inspector(root).checks.all? { |check| check.status == :ok }
    end
  end

  def test_generator_copies_one_template_with_traceable_metadata_and_preserves_reviewed_edits
    with_host do |root|
      generate(root)
      path = target(root)
      assert path.file?
      assert_equal 1, root.glob("**/*").count(&:file?)
      assert_equal :ok, inspector(root).checks.first.status
      assert_equal "CURRENT", inspector(root).checks.first.code
      assert_includes path.read, catalog.source_path(catalog.fetch("resource_index")).read
      path.open("a") { |file| file.puts "<p>Reviewed host content</p>" }
      original = path.binread
      generate(root, force: true)
      assert_equal original, path.binread
      assert_equal :ok, inspector(root).checks.first.status
    end
  end

  def test_a_file_created_after_the_precheck_is_not_overwritten
    with_host do |root|
      destination = target(root)
      original_open = File.method(:open)
      injected = false
      race = lambda do |path, *args, **keywords, &block|
        if Pathname.new(path) == destination && !injected
          injected = true
          original_open.call(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write("Concurrent reviewed host template") }
        end
        original_open.call(path, *args, **keywords, &block)
      end
      File.stub(:open, race) { generate(root) }
      assert injected
      assert_equal "Concurrent reviewed host template", destination.read
    end
  end

  def test_list_unknown_traversal_pretend_and_revoke_never_copy_unrequested_files
    with_host do |root|
      output, = generate(root, nil, list: true)
      assert_includes output, "resource_index"
      assert_empty root.children
      [ "../resource_index", "../../config/credentials", "/etc/passwd", "resources/index", "surface" ].each do |key|
        assert_raises(Rails::Generators::Error) { generate(root, key) }
      end
      assert_empty root.children
      generate(root, pretend: true)
      assert_empty root.children
      generate(root)
      path = target(root)
      original = path.binread
      capture_io { RailsAiAdmin::Generators::OverrideGenerator.new([ "resource_index" ], {}, destination_root: root.to_s, behavior: :revoke).invoke_all }
      assert_equal original, path.binread
    end
  end

  def test_source_changes_and_context_revision_changes_are_independent_upgrade_findings
    with_host do |root|
      generate(root)
      entry = catalog.fetch("resource_index")
      source_root = root.join("upstream")
      source_root.join(entry.path).dirname.mkpath
      source_root.join(entry.path).write(catalog.source_path(entry).read + "\n<p>New upstream markup</p>\n")
      upgraded = RailsAiAdmin::Templates::Catalog.new(source_root: source_root)
      check = inspector(root, catalog: upgraded).checks.first
      assert_equal :review, check.status
      assert_equal "STALE_SOURCE", check.code
      changed_context = RailsAiAdmin::Templates::Catalog.new(entries: [ entry.with(revision: entry.revision + 1) ])
      assert_equal "STALE_CONTRACT", inspector(root, catalog: changed_context).checks.first.code
      assert_equal :ok, inspector(root).checks.first.status
      recorded = JSON.parse(target(root).read.lines.first[/\{.*\}/])
      recorded["gem_version"] = "0.0.9"
      target(root).write("<%# rails_ai_admin:override #{JSON.generate(recorded)} %>\nreviewed body")
      assert_equal :ok, inspector(root).checks.first.status
    end
  end

  def test_manual_and_malformed_headers_are_reported_without_evaluating_or_printing_body
    with_host do |root|
      path = target(root)
      path.dirname.mkpath
      path.write('<%= raise "private template must not execute" %>')
      check = inspector(root).checks.first
      assert_equal :review, check.status
      assert_equal "UNTRACKED", check.code
      refute_includes check.inspect, "private template"
      generate(root, force: true)
      assert_includes path.read, "private template"
      path.delete
      generate(root)
      original = path.read
      metadata = JSON.parse(original.lines.first[/\{.*\}/])
      [ metadata.merge("extra" => "private header"), metadata.merge("key" => "layout"), metadata.merge("format" => 2), metadata.merge("source_sha256" => "private header"), metadata.merge("gem_version" => "private\nversion") ].each do |bad|
        path.write("<%# rails_ai_admin:override #{JSON.generate(bad)} %>\nprivate body")
        check = inspector(root).checks.first
        assert_equal :error, check.status
        assert_equal "INVALID_HEADER", check.code
        refute_includes check.inspect, "private"
      end
      duplicate = JSON.generate(metadata).sub('"format":1', '"format":1,"format":1')
      path.write("<%# rails_ai_admin:override #{duplicate} %>\n")
      assert_equal "INVALID_HEADER", inspector(root).checks.first.code
      path.binwrite("<%# rails_ai_admin:override #{'x' * 1100} %>\n")
      assert_equal "INVALID_HEADER", inspector(root).checks.first.code
      path.binwrite("<%# rails_ai_admin:override \xff %>\n".b)
      assert_equal "INVALID_HEADER", inspector(root).checks.first.code
    end
  end

  def test_unsafe_symlinks_are_neither_written_nor_read
    with_host do |root|
      outside = root.join("outside")
      outside.mkpath
      root.join("app").mkpath
      File.symlink(outside, root.join("app/views"))
      assert_raises(Rails::Generators::Error) { generate(root) }
      assert_empty outside.children
      assert inspector(root).checks.any? { |check| check.code == "UNSAFE_PATH" }
      root.join("app/views").delete
      target(root).dirname.mkpath
      File.symlink(outside.join("missing"), target(root))
      assert_raises(Rails::Generators::Error) { generate(root) }
      assert_equal "UNSAFE_PATH", inspector(root).checks.first.code
    end
  end

  def test_explicit_symlink_host_root_is_resolved_but_a_directory_target_is_a_conflict
    with_host do |root|
      actual = root.join("actual")
      actual.mkpath
      linked = root.join("linked")
      File.symlink(actual, linked)
      generate(linked)
      assert target(actual).file?
      target(actual).delete
      target(actual).mkpath
      assert_raises(Rails::Generators::Error) { generate(linked) }
      assert inspector(actual).checks.any? { |check| check.code == "UNSAFE_PATH" }
    end
  end

  def test_inspection_limit_reports_incomplete_and_doctor_names_the_override
    with_host do |root|
      generate(root)
      assert_raises(RailsAiAdmin::ConfigurationError) { inspector(root, max_files: 257) }
      assert_raises(RailsAiAdmin::ConfigurationError) { inspector(root, max_entries: 1025) }
      4.times { |index| target(root).dirname.join("extra_#{index}.html.erb").write("manual") }
      assert inspector(root, max_files: 2).checks.any? { |check| check.code == "INCOMPLETE" && check.status == :review }
      application = Struct.new(:root).new(root)
      # Isolate template diagnostics from unrelated database/host checks.
      checks = RailsAiAdmin::Doctor.new(application: application).send(:override_checks)
      assert checks.any? { |check| check.name == "override:resource_index" && check.status == :ok }
    end
  end
end
