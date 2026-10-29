# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class ScalarReadsTest < Minitest::Test
  include DatabaseHelpers

  class ReadPolicy < RailsAiAdmin::Authorization::Adapter
    def allowed?(**) = true
    def fields(**) = %i[destroy name id]
  end

  class UnsafeResource < RailsAiAdmin::Resource
    model "Customer"
    key :unsafe_scalar_reads
    readonly true
    title :destroy
    fields { text :destroy }
  end

  def setup
    reset_database
  end

  def with_read_policy
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "ScalarReadsTest::ReadPolicy"
    RailsAiAdmin.stub(:configuration, config) { yield }
  end

  def test_readonly_projection_cannot_invoke_a_nonattribute_model_method
    with_read_policy do
      access = RailsAiAdmin::Authorization::Access.new(context, UnsafeResource)
      assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) }
      assert Customer.exists?(@customer.id)
      assert_equal 0, RailsAiAdmin::AuditEvent.count
    end
  end

  def test_record_label_uses_the_same_guard_before_calling_a_model_method
    with_read_policy do
      controller = RailsAiAdmin::ApplicationController.new
      controller.instance_variable_set(:@context, context)
      assert_raises(RailsAiAdmin::ConfigurationError) { controller.send(:record_label, UnsafeResource, @customer) }
      assert Customer.exists?(@customer.id)
      assert_equal 0, RailsAiAdmin::AuditEvent.count
    end
  end

  def test_id_alias_reads_a_selected_custom_primary_key
    model = Class.new(Customer) { self.primary_key = "account_id" }
    record = model.instantiate("account_id" => 42, "name" => "Selected custom key")
    refute record.has_attribute?("id")
    field = TestResource.fields.find { |candidate| candidate.name == :id }
    value = RailsAiAdmin::Authorization::Access.new(context, TestResource).read_value(record, field)
    assert_equal 42, value
  end

  def test_real_attribute_getters_are_preserved
    with_read_policy do
      @customer.define_singleton_method(:name) { "Host redaction" }
      values = RailsAiAdmin::Authorization::Access.new(context, TestResource).project(@customer)
      assert_equal "Host redaction", values.fetch("name")
      assert_equal @customer.id, values.fetch("id")
    end
  end
end
