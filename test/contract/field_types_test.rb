# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class FieldTypesTest < Minitest::Test
  include DatabaseHelpers

  class EmailType < RailsAiAdmin::Fields::Type
    scalar :text
    version "1"
    def normalize(value, **) = value.strip.downcase
    def valid?(value, **) = value.include?("@")
    def schema(field:) = { pattern: "^[^ @]+@[^ @]+$", maxLength: 40 }
    def format(text, **) = "<#{text}>".html_safe
  end

  class SelectionPolicy < TestPolicy
    def select_records?(**) = true
  end

  class BadType < RailsAiAdmin::Fields::Type
    scalar :text
    class_attribute :hook, default: :schema
    def schema(field:)
      return {} unless self.class.hook == :schema
      Customer.create!(account_id: 1, name: "Forbidden schema write")
      {}
    end
    def normalize(value, **)
      Customer.update_all(name: "Forbidden normalization") if self.class.hook == :normalize
      value
    end
    def valid?(_value, **)
      Customer.delete_all if self.class.hook == :valid?
      true
    end
    def format(text, **)
      Customer.delete_all if self.class.hook == :format
      text
    end
  end

  def setup
    reset_database
  end

  def registry(types = { contact_email: "FieldTypesTest::EmailType" })
    RailsAiAdmin::Fields::Registry.new(types).validate!
  end

  def email(**options) = registry.build(:name, type: :contact_email, **options)

  def test_one_contract_normalizes_validates_and_strips_html_safety
    field = email(nullable: false, max_length: 50)
    assert_equal "alice@example.com", field.coerce(" Alice@Example.COM ")
    result = RailsAiAdmin::InputSchema.new([ field ]).coerce({ "name" => "no-address" })
    refute result.valid?
    assert_equal [ "is invalid" ], result.errors["name"]
    assert_raises(ArgumentError) { field.coerce("a" * 41 + "@b") }
    assert_raises(ArgumentError) { field.coerce({ "nested" => "value" }) }
    formatted = field.format("alice@example.com")
    assert_instance_of String, formatted
    refute formatted.html_safe?
    assert_equal "<alice@example.com>", formatted
    schema = RailsAiAdmin::InputSchema.new([ field ]).json_schema
    assert JSONSchemer.schema(schema).valid?({ "name" => "alice@example.com" })
    refute JSONSchemer.schema(schema).valid?({ "name" => "x" * 41 + "@b" })
  end

  def test_schema_intersection_cannot_widen_core_length_or_nullable
    field = email(max_length: 10, nullable: false)
    refute JSONSchemer.schema(field.json_schema).valid?("alice@example.com")
    refute JSONSchemer.schema(field.json_schema).valid?(nil)
    assert_raises(ArgumentError) { field.coerce(nil) }
    assert_nil email.coerce(nil)
    assert JSONSchemer.schema(email.json_schema).valid?(nil)
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Fields::ScalarSchema.compile({ "type" => "string" }, type: "integer") }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Fields::ScalarSchema.compile({ "type" => "string" }, "$ref" => "file:///secret") }
  end

  def test_schema_rejects_constraints_that_the_wire_type_would_ignore
    [ [ { "type" => "string" }, { minimum: 0 } ], [ { "type" => "integer" }, { minLength: 1 } ],
      [ { "type" => "boolean" }, { pattern: "true" } ], [ { "type" => "string" }, { enum: [ { nested: true } ] } ] ].each do |base, constraints|
      assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Fields::ScalarSchema.compile(base, constraints) }
    end
  end

  def test_formatter_and_schema_argument_errors_are_configuration_failures
    plugin = EmailType.new
    plugin.define_singleton_method(:format) { |*, **| raise ArgumentError, "private details" }
    EmailType.stub(:new, plugin) do
      error = assert_raises(RailsAiAdmin::ConfigurationError) { email.format("a@b") }
      refute_includes error.message, "private details"
    end
    plugin.define_singleton_method(:schema) { |**| raise ArgumentError, "private details" }
    EmailType.stub(:new, plugin) do
      error = assert_raises(RailsAiAdmin::ConfigurationError) { email }
      refute_includes error.message, "private details"
    end
  end

  def test_registration_is_explicit_and_cannot_replace_or_duplicate_builtins
    [ { text: "FieldTypesTest::EmailType" }, { contact_email: EmailType }, { contact_email: "String" }, { contact_email: "MissingType" }, { contact_email: "FieldTypesTest::EmailType", "contact_email" => "FieldTypesTest::EmailType" } ].each do |types|
      assert_raises(RailsAiAdmin::ConfigurationError) { registry(types) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { registry.build(:name, type: :unregistered) }
  end

  def test_metadata_and_schema_are_deeply_immutable
    field = email
    assert_raises(FrozenError) { field.options[:max_length] = 100 }
    assert_raises(FrozenError) { field.json_schema["anyOf"].first["allOf"].first["pattern"] << "untrusted" }
    assert_raises(FrozenError) { field.contract[:plugin][:version] << "2" }
    choices = [ [ "Draft".dup, "draft" ], [ "Published", "published" ] ]
    select = RailsAiAdmin::Field.new(:name, type: :select, choices: choices)
    choices.first.first.replace("Changed")
    assert_equal "Draft", select.format("draft")
    assert_raises(FrozenError) { select.choice_options.first.first << "!" }
  end

  def test_fixed_select_labels_values_and_blank_semantics
    field = RailsAiAdmin::Field.new(:name, type: :select, choices: [ [ "Pending review", "pending" ], [ "Approved", "approved" ] ])
    assert_equal "pending", field.coerce("pending")
    assert_equal "Pending review", field.format("pending")
    assert_nil field.coerce("")
    assert_raises(ArgumentError) { field.coerce("Pending review") }
    assert_raises(ArgumentError) { field.coerce(1) }
    assert_raises(ArgumentError) { RailsAiAdmin::Field.new(:name, type: :select, values: [ "pending" ], nullable: false).coerce("") }
    [ [], [ [ "A", "a" ], [ "B", "a" ] ], [ [ "A", 1 ] ], [ [ "", "a" ] ] ].each do |choices|
      assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:name, type: :select, choices: choices) }
    end
  end

  def test_hooks_prevent_normal_active_record_writes_without_exposing_details
    %i[schema normalize valid? format].each do |hook|
      BadType.hook = hook
      error = assert_raises(RailsAiAdmin::ConfigurationError) do
        field = registry(bad: "FieldTypesTest::BadType").build(:name, type: :bad)
        hook == :format ? field.format("Alice") : field.coerce("Alice")
      end
      refute_includes error.message, "Forbidden"
      assert_equal "Alice", @customer.reload.name
      assert_equal 2, Customer.count
    end
  end

  def test_registered_class_is_resolved_fresh_and_version_changes_invalidate_old_fields
    original = EmailType.version
    field = email
    EmailType.version "2"
    assert_raises(RailsAiAdmin::ConfigurationError) { field.coerce("alice@example.com") }
    refute_equal field.contract, email.contract
  ensure
    EmailType.version original
  end

  def test_plugin_version_change_invalidates_captured_selection
    original = EmailType.version
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "FieldTypesTest::SelectionPolicy"
    RailsAiAdmin.stub(:configuration, config) do
      builder = RailsAiAdmin::Selections::Builder.new
      capture = TestResource.stub(:fields, [ email ]) do
        builder.capture(context: context, resource: TestResource, target_ids: [ @customer.id ])
      end
      EmailType.version "2"
      TestResource.stub(:fields, [ email ]) do
        error = assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: capture.selection_ref) }
        assert_equal "SELECTION_INVALIDATED", error.code
      end
    end
  ensure
    EmailType.version original
  end

  def test_non_idempotent_and_mutating_normalization_fails_closed
    EmailType.stub(:new, EmailType.new.tap { |plugin| plugin.define_singleton_method(:normalize) { |value, **| value + "x" } }) do
      assert_raises(RailsAiAdmin::ConfigurationError) { email.coerce("a@b") }
    end
    EmailType.stub(:new, EmailType.new.tap { |plugin| plugin.define_singleton_method(:normalize) { |value, **| value << "x" } }) do
      assert_raises(RailsAiAdmin::ConfigurationError) { email.coerce("a@b") }
    end
  end

  def test_readonly_dsl_still_requires_a_model_attribute
    fields = {}
    builder = RailsAiAdmin::Resource::FieldBuilder.new(fields)
    builder.readonly(:name)
    refute fields[:name].writable?(:update)
    assert_raises(RailsAiAdmin::ConfigurationError) { builder.text(:name) }
    builder.readonly(:destroy)
    access = RailsAiAdmin::Authorization::Access.new(context, TestResource)
    assert_raises(RailsAiAdmin::ConfigurationError) { access.read_value(@customer, fields[:destroy]) }
    assert Customer.exists?(@customer.id)
  end
end
