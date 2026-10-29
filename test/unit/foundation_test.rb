# frozen_string_literal: true

require "test_helper"

class FoundationTest < Minitest::Test
  def test_default_policy_grants_nothing
    adapter = RailsAiAdmin::Authorization::Adapter.new
    refute adapter.allowed?(context: context, action: :index, resource: TestResource)
    assert_empty adapter.fields(context: context, resource: TestResource, action: :write)
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
    assert_raises(FrozenError) { config.resources << "UnexpectedAdmin" }
  end

  def test_rails_default_inflections_are_preserved
    assert_equal "RailsAiAdmin", "rails_ai_admin".camelize
    assert_equal "Ai", "ai".camelize
    assert_equal "Assistant", "assistant".camelize
  end
end
