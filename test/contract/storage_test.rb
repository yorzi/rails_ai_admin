# frozen_string_literal: true

require "test_helper"
require "support/database"

class SeparatePoolCustomer < ActiveRecord::Base
  self.table_name = "customers"
end
class SeparatePoolAdmin < RailsAiAdmin::Resource
  model "SeparatePoolCustomer"
  key :separate_customers
  title :name
  fields { text :name }
end

class UnlockedCustomer < ActiveRecord::Base
  self.table_name = "customers"
  self.lock_optimistically = false
end
class UnlockedAdmin < RailsAiAdmin::Resource
  model "UnlockedCustomer"
  key :unlocked_customers
  title :name
  fields { text :name }
end

class StorageTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
  end

  def test_same_database_in_a_different_pool_is_rejected
    SeparatePoolCustomer.establish_connection(Customer.connection_db_config.configuration_hash)
    assert_raises(RailsAiAdmin::ConfigurationError) do
      RailsAiAdmin::Operations::Runner.new.prepare(context: context, resource: SeparatePoolAdmin, operation: :update, target_id: @customer.id, expected_version: 0)
    end
    assert_equal "Alice", @customer.reload.name
  ensure
    SeparatePoolCustomer.remove_connection
  end

  def test_models_without_optimistic_locking_are_rejected_for_generic_writes
    assert_raises(RailsAiAdmin::ConfigurationError) do
      RailsAiAdmin::Operations::Runner.new.prepare(context: context, resource: UnlockedAdmin, operation: :update, target_id: @customer.id, expected_version: 0)
    end
  end
  def test_uuid_targets_and_created_receipts_round_trip_without_integer_coercion
    record = UuidCustomer.create!(account_id: 1, name: "UUID record")
    runner = RailsAiAdmin::Operations::Runner.new
    intent = runner.prepare(context: context, resource: UuidCustomerAdmin, operation: :update,
      target_id: record.id, expected_version: record.lock_version)
    result = runner.execute(context: context, intent_ref: intent.id, input: { "name" => "UUID edited" }, human_confirmed: true)
    assert result.success?, result.code
    assert_equal record.id, result.record_id
    assert_equal "UUID edited", record.reload.name
    assert runner.execute(context: context, intent_ref: intent.id, input: { "name" => "UUID edited" }, human_confirmed: true).replayed
    create = runner.prepare(context: context, resource: UuidCustomerAdmin, operation: :create)
    created = runner.execute(context: context, intent_ref: create.id, input: { "name" => "Created UUID" }, human_confirmed: true)
    assert created.success?, created.code
    assert_match(/\A[0-9a-f-]{36}\z/, created.record_id)
    assert_equal 1, UuidCustomer.find(created.record_id).account_id
  end
end
