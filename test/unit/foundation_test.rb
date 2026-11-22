# frozen_string_literal: true

require "test_helper"

class FoundationTest < Minitest::Test
  def test_default_policy_grants_nothing
    adapter = RailsAiAdmin::Authorization::Adapter.new
    refute adapter.allowed?(context: context, action: :index, resource: TestResource)
    assert_empty adapter.fields(context: context, resource: TestResource, action: :write)
    refute adapter.select_records?(context: context, resource: TestResource)
  end

  def test_context_has_typed_bounded_identities
    assert_equal "raa:actor:TestActor:1", context.actor_ref
    assert_equal "raa:tenant:TestTenant:1", context.tenant_ref
    refute_equal context.actor_ref, context.tenant_ref
    assert context.frozen?
    assert_raises(RailsAiAdmin::AccessDenied) { context(actor: nil) }
    assert_raises(RailsAiAdmin::AccessDenied) { context(actor: "x" * 200) }
    assert_raises(RailsAiAdmin::AccessDenied) { context(version: "") }
  end

  def test_registry_is_explicit_and_rejects_duplicate_keys
    registry = RailsAiAdmin::Registry.new([ "TestResource" ])
    assert_same TestResource, registry.fetch("customers")
    assert_raises(RailsAiAdmin::AccessDenied) { registry.fetch("Customer") }
    assert_raises(RailsAiAdmin::AccessDenied) { registry.fetch("Object") }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Registry.new([ "TestResource", "TestResource" ]) }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Registry.new([ "String" ]) }
  end

  def test_configuration_stores_names_and_freezes
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = TestActor
    assert_raises(RailsAiAdmin::ConfigurationError) { config.finalize! }
    config.context_adapter = "AdminContext"
    config.resources = [ "TestResource" ]
    config.finalize!
    assert config.frozen?
    assert_same config, config.finalize!
    assert_raises(FrozenError) { config.resources << "UnexpectedAdmin" }
  end

  def test_configuration_validates_adapters_resources_title_and_fallbacks
    invalid = [
      ->(config) { config.authorization_adapter = nil },
      ->(config) { config.resources = [ "not a constant" ] },
      ->(config) { config.title = "" },
      ->(config) { config.title = "Admin\nInjected" },
      ->(config) { config.assistant_fallback_models = nil }
    ]
    invalid.each do |mutate|
      config = RailsAiAdmin::Configuration.new
      mutate.call(config)
      assert_raises(RailsAiAdmin::ConfigurationError) { config.finalize! }
    end
  end

  def test_plugin_field_types_reject_excluded_scalars
    RailsAiAdmin::Field::PLUGIN_EXCLUDED.each do |excluded|
      klass = Class.new(RailsAiAdmin::Fields::Type) { scalar excluded }
      assert_raises(RailsAiAdmin::ConfigurationError, excluded.to_s) { klass.metadata }
    end
  end

  def test_record_version_accepts_postgresql_timestamptz
    column = Struct.new(:type).new(:timestamptz)
    model = Struct.new(:locking_enabled?, :locking_column, :columns_hash, :record_timestamps)
      .new(false, "lock_version", { "updated_at" => column }, true)
    assert_equal :updated_at, RailsAiAdmin::RecordVersion.strategy(model)
  end

  def test_rails_default_inflections_are_preserved
    assert_equal "RailsAiAdmin", "rails_ai_admin".camelize
    assert_equal "Ai", "ai".camelize
    assert_equal "Assistant", "assistant".camelize
  end
end
