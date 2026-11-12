# frozen_string_literal: true

require "test_helper"
require "support/database"
require "support/collections"
require "rails_ai_admin/schema_suggestions"
require "rails_ai_admin/test_kit"
require "rails_ai_admin/doctor"
require "generators/rails_ai_admin/resource/resource_generator"
require "generators/rails_ai_admin/install/install_generator"
require "tmpdir"

class SchemaSuggestionRecord < ActiveRecord::Base
  self.table_name = "schema_suggestion_records"
  belongs_to :customer, foreign_key: :owner_ref
  belongs_to :attachable, polymorphic: true
  belongs_to :account
  encrypts :private_memo
  enum :state, { open: 0, closed: 1 }
end

class InvalidSchemaAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :schema_invalid
  title :unavailable
  fields do
    text :unavailable, sortable: true
    textarea :secret
  end
end

class MismatchedSchemaAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :type_mismatch
  title :name
  fields do
    datetime :name
  end
end

class NoArgumentContext
  def resolve = nil
end

class LifecycleFieldAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :lifecycle_fields
  title :name
  fields do
    text :name, create: false
    integer :points, edit: false
  end
end

class PrivateConstructorContext
  private_class_method :new
  def resolve(_controller) = nil
end

class DeveloperToolsTest < Minitest::Test
  include DatabaseHelpers
  include CollectionContractHelpers

  def setup
    reset_database
    ActiveRecord::Schema.define do
      create_table :schema_suggestion_records, force: true do |t|
        t.string :name, limit: 80, null: false
        t.text :description
        t.decimal :price, precision: 8, scale: 2
        t.boolean :active
        t.date :starts_on
        t.integer :state
        t.string :password_digest
        t.string :api_token
        t.string :secret_note
        t.text :private_memo
        t.integer :customer_id
        t.integer :owner_ref
        t.integer :linked_ref
        t.foreign_key :customers, column: :linked_ref
        t.references :attachable, polymorphic: true
        t.integer :account_id
        t.string :type
        t.json :metadata
        t.integer :lock_version
        t.timestamps
      end
    end
    SchemaSuggestionRecord.reset_column_information
  end

  def test_schema_suggestions_omit_sensitive_encrypted_relationship_and_unsupported_columns
    report = RailsAiAdmin::SchemaSuggestions.new(SchemaSuggestionRecord).call
    assert report.available
    assert_equal %w[name description price active starts_on state customer created_at updated_at], report.suggestions.map(&:name)
    assert_equal 12, report.omitted, "the tenant reference account_id stays omitted"
    # Only a declared non-polymorphic belongs_to suggests a reference; a bare
    # _id column, a database-only foreign key and a polymorphic pair do not.
    assert_equal "belongs_to :customer, foreign_key: \"owner_ref\"", report.suggestions.find { |entry| entry.name == "customer" }.declaration
    name = report.suggestions.find { |entry| entry.name == "name" }
    assert_equal "text :name, nullable: false, max_length: 80", name.declaration
    assert_equal "enum :state, values: [\"open\", \"closed\"]", report.suggestions.find { |entry| entry.name == "state" }.declaration
    assert report.suggestions.find { |entry| entry.name == "created_at" }.options[:readonly]
    # RAA-004: decimal limits are written into the suggested declaration.
    assert_equal "decimal :price, precision: 8, scale: 2", report.suggestions.find { |entry| entry.name == "price" }.declaration
  end

  def test_generator_only_enables_readonly_id_and_never_samples_records
    sql = []
    listener = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }
    Dir.mktmpdir("raa-generator-", File.expand_path("../../tmp", __dir__)) do |directory|
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        generator = RailsAiAdmin::Generators::ResourceGenerator.new([ "SchemaSuggestionRecord" ], [], destination_root: directory)
        capture_io { generator.invoke_all }
      end
      source = File.read(File.join(directory, "app/rails_ai_admin/schema_suggestion_record_admin.rb"))
      assert_includes source, "# text :name, nullable: false, max_length: 80"
      refute_match(/password_digest|api_token|secret_note|private_memo|customer_id|linked_ref|metadata|lock_version|attachable|text :type/, source)
      # The declared reference column appears only as a commented suggestion.
      assert_equal [ %(    # belongs_to :customer, foreign_key: "owner_ref"\n) ], source.lines.grep(/owner_ref/)
      active = source.lines.reject { |line| line.lstrip.start_with?("#") }.join
      assert_includes active, "readonly"
      assert_match(/fields do\s+id :id\s+end/, active)
      RubyVM::InstructionSequence.compile(source)
      refute sql.any? { |statement| statement.match?(/\b(?:FROM|UPDATE|INTO)\s+["`]?schema_suggestion_records\b/i) }, sql.join("\n")
    end
  end

  def test_unavailable_schema_falls_back_to_an_unregistered_readonly_resource
    refute RailsAiAdmin::SchemaSuggestions.new(nil).call.available
    Dir.mktmpdir("raa-generator-", File.expand_path("../../tmp", __dir__)) do |directory|
      generator = RailsAiAdmin::Generators::ResourceGenerator.new([ "NoSchemaModel" ], [], destination_root: directory)
      capture_io { generator.invoke_all }
      source = File.read(File.join(directory, "app/rails_ai_admin/no_schema_model_admin.rb"))
      assert_includes source, "Schema unavailable"
      assert_includes source, "readonly"
      refute RailsAiAdmin.registry.resources.any? { |resource| resource.model == "NoSchemaModel" }
    end
  end

  def test_field_grant_snapshot_detects_both_expansion_and_revocation
    expected = { read: %i[id name points active], write: %i[name points active], search: [ :name ], sort: [ :name ], filter: [] }
    assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TestResource, record: @customer, expected: expected)
    report = RailsAiAdmin::TestKit.field_grants(context: context, resource: TestResource, record: @customer)
    assert_equal %w[active id name points], report.fetch("read")
    refute_includes report.inspect, @customer.secret
    TestPolicy.hide_name = true
    assert_raises(RailsAiAdmin::TestKit::AssertionError) do
      RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TestResource, record: @customer, expected: expected)
    end
    reader = RailsAiAdmin::TestKit.field_grants(context: context(actor: 2), resource: TestResource, record: @customer)
    assert_empty reader.fetch("write")
    assert_raises(ArgumentError) { RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TestResource, expected: { read: [] }) }
    assert_raises(ArgumentError) { RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: TestResource, expected: expected.except(:filter)) }
    TestPolicy.hide_name = false
    TestPolicy.granted_filters = %i[points secret]
    assert_equal [ "points" ], RailsAiAdmin::TestKit.field_grants(context: context, resource: TestResource).fetch("filter")
    assert RailsAiAdmin::TestKit.assert_hidden(context: context, resource: TestResource, field: :active, actions: [ :filter ])
  end

  def test_field_snapshots_respect_separate_create_edit_and_query_flags
    grants = { read: %i[name points], write: [ :points ], search: [], sort: [], filter: [] }
    assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: LifecycleFieldAdmin, record: @customer, operation: :create, expected: grants)
    assert RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: LifecycleFieldAdmin, record: @customer, operation: :update, expected: grants.merge(write: [ :name ]))
    assert_raises(ArgumentError) { RailsAiAdmin::TestKit.field_grants(context: context, resource: LifecycleFieldAdmin, operation: nil) }
  end

  def test_anonymous_context_assertion_and_doctor_do_not_attest_metadata_as_security
    closed = Object.new
    def closed.resolve(_controller) = nil
    assert RailsAiAdmin::TestKit.assert_unauthenticated(adapter: closed, controller: nil)
    open_adapter = Object.new
    valid_context = context
    open_adapter.define_singleton_method(:resolve) { |_controller| valid_context }
    assert_raises(RailsAiAdmin::TestKit::AssertionError) { RailsAiAdmin::TestKit.assert_unauthenticated(adapter: open_adapter, controller: nil) }
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "String"
    checks = RailsAiAdmin::Doctor.new(configuration: config, registry: RailsAiAdmin::Registry.new([ "InvalidSchemaAdmin" ]), application: nil).checks
    assert_equal :error, checks.find { |entry| entry.name == "context" }.status
    assert_equal :closed, checks.find { |entry| entry.name == "policy" }.status
    assert_equal :error, checks.find { |entry| entry.name == "schema:schema_invalid" }.status
    assert_equal :review, checks.find { |entry| entry.name == "sensitivity:schema_invalid" }.status
    assert_equal :review, checks.find { |entry| entry.name == "sort_indexes:schema_invalid" }.status
    refute_includes checks.map(&:message).join, @customer.secret
  end

  def test_doctor_recognizes_definitely_incompatible_signatures_and_field_types
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "NoArgumentContext"
    checks = RailsAiAdmin::Doctor.new(configuration: config, registry: RailsAiAdmin::Registry.new([ "MismatchedSchemaAdmin" ]), application: nil).checks
    assert_equal :error, checks.find { |entry| entry.name == "context" }.status
    assert_equal :review, checks.find { |entry| entry.name == "field_types:type_mismatch" }.status
    config.context_adapter = "PrivateConstructorContext"
    checks = RailsAiAdmin::Doctor.new(configuration: config, registry: RailsAiAdmin::Registry.new([]), application: nil).checks
    assert_equal :error, checks.find { |entry| entry.name == "context" }.status
  end

  def test_doctor_reports_missing_selection_tables_without_granting_selection
    RailsAiAdmin::Selection.stub(:table_exists?, false) do
      checks = RailsAiAdmin::Doctor.new(application: nil).checks
      check = checks.find { |entry| entry.name == "selections" }
      assert_equal :error, check.status
      assert_includes check.message, "installed=false"
      refute RailsAiAdmin::Authorization::Adapter.new.select_records?(context: context, resource: TestResource)
    end
  end

  # Rails shares mounted helper definitions across RouteSets. Draw the real
  # application's mount first, then isolate mutable engine routes in fake probes.
  def with_isolated_engine_routes
    Rails.application.routes.url_helpers.rails_ai_admin_path if Rails.application
    isolated_routes = ActionDispatch::Routing::RouteSet.new
    RailsAiAdmin::Engine.instance.stub(:routes, ->(*) { isolated_routes }) { yield }
  end

  def test_install_preserves_reviewed_extra_scaffolds_even_when_forced
    with_isolated_engine_routes do
      Dir.mktmpdir("raa-install-", File.expand_path("../../tmp", __dir__)) do |directory|
        FileUtils.mkdir_p(File.join(directory, "config"))
        File.write(File.join(directory, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
        application = Struct.new(:root, :routes).new(Pathname.new(directory), ActionDispatch::Routing::RouteSet.new)
        capture_io { RailsAiAdmin::Generators::InstallGenerator.new([], { force: true }, destination_root: directory, application: application).invoke_all }
        paths = %w[app/rails_ai_admin/admin_policy_adapter.rb app/rails_ai_admin/example_admin.rb test/rails_ai_admin/access_test.rb]
        paths.each { |path| File.open(File.join(directory, path), "a") { |file| file.puts "# reviewed host extension" } }
        # A migration from an older engine build may already have run; a forced
        # re-install keeps it instead of recreating it under a new timestamp.
        installed = Dir[File.join(directory, "db/migrate/*.rb")].sort
        File.open(installed.first, "a") { |file| file.puts "# copied from an older engine build" }
        application.routes.draw { mount RailsAiAdmin::Engine => "/admin", as: :rails_ai_admin }
        output, = capture_io { RailsAiAdmin::Generators::InstallGenerator.new([], { force: true }, destination_root: directory, application: application).invoke_all }
        paths.each { |path| assert_includes File.read(File.join(directory, path)), "# reviewed host extension" }
        assert_equal installed, Dir[File.join(directory, "db/migrate/*.rb")].sort
        assert_includes File.read(installed.first), "# copied from an older engine build"
        assert_equal 5, output.scan(/exist\s+db\/migrate\//).size
        assert_equal 1, File.read(File.join(directory, "config/routes.rb")).scan("mount RailsAiAdmin::Engine").size
      end
    end
  end

  def test_install_rejects_unsupported_alias_before_writing_any_scaffolds
    with_isolated_engine_routes do
      Dir.mktmpdir("raa-install-", File.expand_path("../../tmp", __dir__)) do |directory|
        FileUtils.mkdir_p(File.join(directory, "config"))
        source = "Rails.application.routes.draw do\n  mount(RailsAiAdmin::Engine => '/staff', as: :staff_admin)\nend\n"
        File.write(File.join(directory, "config/routes.rb"), source)
        routes = ActionDispatch::Routing::RouteSet.new
        routes.draw { mount RailsAiAdmin::Engine => "/staff", as: :staff_admin }
        application = Struct.new(:root, :routes).new(Pathname.new(directory), routes)
        assert_raises(Rails::Generators::Error) do
          capture_io { RailsAiAdmin::Generators::InstallGenerator.new([], { force: true }, destination_root: directory, application: application).invoke_all }
        end
        assert_equal source, File.read(File.join(directory, "config/routes.rb"))
        refute File.exist?(File.join(directory, "app"))
        refute File.exist?(File.join(directory, "db"))
      end
    end
  end

  def test_mount_inspection_uses_actual_final_route_names_and_rejects_parameters
    with_isolated_engine_routes do
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw { self.mount(::RailsAiAdmin::Engine, at: "/staff", as: "rails_ai_admin") }
      assert_equal [ "rails_ai_admin" ], RailsAiAdmin::Generators::EngineMounts.names(routes)
      routes.draw do
        namespace :ops do
          mount RailsAiAdmin::Engine => "/staff", as: :rails_ai_admin
        end
      end
      assert_equal [ "ops_rails_ai_admin" ], RailsAiAdmin::Generators::EngineMounts.names(routes)
      routes.draw do
        scope "/:locale" do
          mount RailsAiAdmin::Engine => "/staff", as: :rails_ai_admin
        end
      end
      assert_equal [ :unsupported ], RailsAiAdmin::Generators::EngineMounts.names(routes)
    end
  end

  def test_install_rejects_a_name_owned_by_a_different_endpoint_before_writing
    Dir.mktmpdir("raa-install-", File.expand_path("../../tmp", __dir__)) do |directory|
      FileUtils.mkdir_p(File.join(directory, "config"))
      source = "Rails.application.routes.draw do\nend\n"
      File.write(File.join(directory, "config/routes.rb"), source)
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw { get "/occupied", to: ->(_env) { [ 200, {}, [] ] }, as: :rails_ai_admin }
      application = Struct.new(:root, :routes).new(Pathname.new(directory), routes)
      assert_raises(Rails::Generators::Error) do
        capture_io { RailsAiAdmin::Generators::InstallGenerator.new([], { force: true }, destination_root: directory, application: application).invoke_all }
      end
      assert_equal source, File.read(File.join(directory, "config/routes.rb"))
      refute File.exist?(File.join(directory, "app"))
      refute File.exist?(File.join(directory, "db"))
    end
  end

  def test_install_rejects_a_host_constant_collision_before_writing
    created = !Object.const_defined?(:ExampleAdmin)
    Object.const_set(:ExampleAdmin, Class.new) if created
    Dir.mktmpdir("raa-install-", File.expand_path("../../tmp", __dir__)) do |directory|
      FileUtils.mkdir_p(File.join(directory, "config"))
      source = "Rails.application.routes.draw do\nend\n"
      File.write(File.join(directory, "config/routes.rb"), source)
      application = Struct.new(:root, :routes).new(Pathname.new(directory), ActionDispatch::Routing::RouteSet.new)
      assert_raises(Rails::Generators::Error) do
        capture_io { RailsAiAdmin::Generators::InstallGenerator.new([], { force: true }, destination_root: directory, application: application).invoke_all }
      end
      assert_equal source, File.read(File.join(directory, "config/routes.rb"))
      refute File.exist?(File.join(directory, "app"))
      refute File.exist?(File.join(directory, "db"))
    end
  ensure
    Object.send(:remove_const, :ExampleAdmin) if created
  end
  def test_doctor_recognizes_collection_queues_even_without_outbox_handlers
    with_collection do
      checks = RailsAiAdmin::Doctor.new(application: nil, work_registry: RailsAiAdmin::Outbox::Registry.new({})).checks
      queue = checks.find { |check| check.name == "queue" }
      assert_equal :review, queue.status
      assert_includes queue.message, "1 collection handlers"
      assert checks.any? { |check| check.name == "job_context" }
    end
  end
end
