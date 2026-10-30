# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class PresentationFieldsTest < Minitest::Test
  include DatabaseHelpers

  class Summary < RailsAiAdmin::Fields::Computation
    class_attribute :calls, default: 0
    def call(values, **)
      self.class.calls += 1
      "#{values.fetch('name')}: #{values.fetch('points')}"
    end
  end
  class Resource < RailsAiAdmin::Resource
    model "Customer"
    key :presentation_customers
    title :name
    fields do
      id :id, create: false
      text :name, index: false, searchable: :prefix, sortable: true, tab: "Identity", panel: "Basics", help_text: "Use the preferred name."
      integer :points, index: false, tab: "Account", panel: "Rewards"
      text :secret, hidden: true, searchable: :prefix, sortable: true, tab: "Private group"
      virtual :summary, type: :text, depends_on: %i[name points], compute: "PresentationFieldsTest::Summary", edit: true, tab: "Account"
    end
  end
  class Policy < TestPolicy
    class_attribute :mask, default: nil
    def fields(**) = super + %i[secret summary]
    def presentation_fields(context:, resource:, view:, record: nil) = self.class.mask
  end

  def setup
    reset_database
    Summary.calls = 0
    Policy.mask = nil
  end

  def with_access
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "PresentationFieldsTest::Policy"
    RailsAiAdmin.stub(:configuration, config) { yield RailsAiAdmin::Authorization::Access.new(context, Resource) }
  end

  def test_static_output_flags_do_not_remove_explicitly_granted_computation_dependencies
    with_access do |access|
      values = access.project(@customer, view: :index)
      assert_equal %w[id summary], values.keys.sort
      assert_equal "Alice: 0", values.fetch("summary")
      assert_equal 1, Summary.calls
      name = Resource.fields.find { |field| field.name == :name }
      assert_raises(RailsAiAdmin::AccessDenied) { access.read_value(@customer, name, view: :index) }
      assert_equal "Alice", access.read_value(@customer, name, view: :show)
      assert_equal "Record ##{@customer.id}", access.record_label(@customer, values: values, view: :index)
      assert_equal "Alice", access.record_label(@customer, view: :show)
      assert_includes access.fields(:read, @customer).map(&:name), :name
    end
  end

  def test_view_permission_denial_suppresses_recursive_dependencies_before_getters
    Policy.mask = %i[id summary]
    @customer.define_singleton_method(:name) { raise "Denied getter was called" }
    with_access do |access|
      assert_equal [ "id" ], access.project(@customer, view: :index).keys
      assert_equal 0, Summary.calls
      name = Resource.fields.find { |field| field.name == :name }
      assert_raises(RailsAiAdmin::AccessDenied) { access.read_value(@customer, name, view: :index) }
      assert_equal "Record ##{@customer.id}", access.record_label(@customer, view: :show)
    end
  end

  def test_hidden_is_a_global_narrowing_even_when_every_policy_grants_it
    with_access do |access|
      %i[read write search sort].each { |action| refute_includes access.fields(action, @customer).map(&:name), :secret }
      secret = Resource.fields.find { |field| field.name == :secret }
      assert_raises(RailsAiAdmin::AccessDenied) { access.read_value(@customer, secret) }
      refute secret.writable?(:create)
      refute secret.writable?(:update)
    end
  end

  def test_write_view_mask_is_rechecked_by_the_generic_runner
    registry = RailsAiAdmin::Registry.new([ "PresentationFieldsTest::Resource" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    with_access do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          runner = RailsAiAdmin::Operations::Runner.new
          intent = runner.prepare(context: context, resource: Resource, operation: :update, target_id: @customer.id, expected_version: 0)
          Policy.mask = [ :points ]
          result = runner.execute(context: context, intent_ref: intent.id, input: { name: "Forbidden" }, human_confirmed: true)
          assert_equal "VALIDATION_FAILED", result.code
          assert_equal "Alice", @customer.reload.name
          assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
        end
      end
    end
  end

  def test_bad_view_masks_fail_closed_and_invalid_views_are_rejected
    with_access do |access|
      [ true, "name", [ Object.new ] ].each do |mask|
        Policy.mask = mask
        assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer, view: :index) }
      end
      assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer, view: :arbitrary) }
    end
  end

  def test_create_rechecks_the_view_mask_after_input_assignment
    registry = RailsAiAdmin::Registry.new([ "PresentationFieldsTest::Resource" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    with_access do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          hook = ->(record: nil, **) { record && record.points.to_i > 10 ? [ :points ] : nil }
          Policy.stub(:new, Policy.new.tap { |policy| policy.define_singleton_method(:presentation_fields, &hook) }) do
            runner = RailsAiAdmin::Operations::Runner.new
            intent = runner.prepare(context: context, resource: Resource, operation: :create)
            before = Customer.count
            result = runner.execute(context: context, intent_ref: intent.id, input: { name: "Forbidden after assignment", points: "11" }, human_confirmed: true)
            assert_equal "NOT_FOUND", result.code
            assert_equal before, Customer.count
            assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
          end
        end
      end
    end
  end

  def test_private_wrong_signature_and_writing_view_hooks_fail_closed
    with_access do
      hooks = [
        Class.new(Policy) { private; def presentation_fields(**) = nil },
        Class.new(Policy) { def presentation_fields = nil },
        Class.new(Policy) { def presentation_fields(**); Customer.update_all(points: 999); nil; end }
      ]
      hooks.each do |klass|
        Policy.stub(:new, klass.new) do
          access = RailsAiAdmin::Authorization::Access.new(context, Resource)
          assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer, view: :index) }
        end
      end
      assert_equal 0, @customer.reload.points
    end
  end

  def test_presentation_metadata_is_plain_bounded_and_immutable
    source = "<b>Not HTML</b>".html_safe
    field = RailsAiAdmin::Field.new(:name, type: :text, help_text: source, tab: "Identity", panel: "Basics")
    assert_instance_of String, field.options[:help_text]
    refute field.options[:help_text].html_safe?
    assert_raises(FrozenError) { field.options[:help_text] << "!" }
    [ { index: nil }, { show: "yes" }, { hidden: 1 }, { tab: "" }, { panel: "x" * 81 }, { help_text: "x" * 501 } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:name, type: :text, **options) }
    end
    summary = Resource.fields.find(&:virtual?)
    assert summary.visible_on?(:edit)
    refute summary.writable?(:update)
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::InputSchema.new([ summary ]) }
  end
end
