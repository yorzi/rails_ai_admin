# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class TemporalInputsTest < Minitest::Test
  include DatabaseHelpers

  class DateType < RailsAiAdmin::Fields::Type
    scalar :date
  end
  class TimestampType < RailsAiAdmin::Fields::Type
    scalar :datetime
    def normalize(value, **) = value.to_datetime
  end
  class PriceType < RailsAiAdmin::Fields::Type
    scalar :decimal
    def normalize(value, **) = value.round(2)
  end
  class Schedule < RailsAiAdmin::Operation
    input do
      date :on, nullable: false, required: true
      datetime :at, nullable: false, required: true
      decimal :amount, nullable: false, required: true
    end
    def preflight(_context, _record, input)
      { name: "#{input.fetch('on').iso8601} / #{input.fetch('at').iso8601} / #{input.fetch('amount').to_s('F')}" }
    end
    def perform(_context, record, input)
      record.update!(name: "#{input.fetch('on').iso8601} / #{input.fetch('at').iso8601} / #{input.fetch('amount').to_s('F')}")
      success(record)
    end
  end
  class ScheduleResource < RailsAiAdmin::Resource
    model "Customer"
    key :scheduled_customers
    title :name
    fields { text :name }
    operation :schedule, handler: "TemporalInputsTest::Schedule"
  end
  class Policy < TestPolicy
    def operation_fields(**) = %i[on at amount]
    def read_operation_receipt?(**) = true
  end

  def setup = reset_database

  def test_typed_scalar_and_plugin_values_can_be_recoerced_without_mutating_the_caller
    types = RailsAiAdmin::Fields::Registry.new(day: "TemporalInputsTest::DateType", timestamp: "TemporalInputsTest::TimestampType", price: "TemporalInputsTest::PriceType")
    inputs = { day: "2026-10-30", timestamp: "2026-10-30T09:30:00.123456+08:00", price: "1.005" }
    inputs.each do |type, wire|
      field = types.build(:value, type: type, nullable: false)
      typed = field.coerce(wire)
      assert_equal 123_456, typed.usec if type == :timestamp
      refute typed.frozen? if typed.is_a?(Time)
      again = field.coerce(typed)
      assert_equal typed, again
      assert_equal RailsAiAdmin::InputSchema.digest(typed), RailsAiAdmin::InputSchema.digest(again)
      refute typed.frozen? if typed.is_a?(Time)
    end
    decimal = RailsAiAdmin::Field.new(:amount, type: :decimal)
    assert_raises(ArgumentError) { decimal.coerce(BigDecimal("NaN")) }
    assert_raises(ArgumentError) { decimal.coerce(BigDecimal("Infinity")) }
    local = Time.new(2026, 10, 30, 9, 30, 0, "+08:00")
    field = RailsAiAdmin::Field.new(:at, type: :datetime)
    assert_equal Time.utc(2026, 10, 30, 1, 30), field.coerce(local)
    refute local.frozen?
    assert_equal 28_800, local.utc_offset
    assert_equal Time.utc(2026, 10, 30, 1, 30), field.coerce(local.to_datetime)
    assert_raises(ArgumentError) { RailsAiAdmin::Field.new(:day, type: :date).coerce(local.to_datetime) }
  end

  def test_public_operation_proposal_values_confirm_and_replay_without_a_json_roundtrip
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "TemporalInputsTest::Policy"
    resources = RailsAiAdmin::Registry.new([ "TemporalInputsTest::ScheduleResource" ])
    operations = RailsAiAdmin::Operations::Registry.new(resources.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, resources) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          runner = RailsAiAdmin::Operations::Runner.new
          proposal = runner.preflight(context: context, resource: ScheduleResource, operation: :schedule,
            target_id: @customer.id, expected_version: @customer.lock_version,
            input: { on: "2026-10-30", at: "2026-10-30T09:30:00+08:00", amount: "0.10" })
          assert_instance_of Date, proposal.values.fetch("on")
          assert_instance_of Time, proposal.values.fetch("at")
          assert_instance_of BigDecimal, proposal.values.fetch("amount")
          first = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
          assert first.success?, "#{first.code}: #{first.errors}"
          second = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
          assert second.replayed
          assert_equal first.audit_ref, second.audit_ref
          assert_equal 1, @customer.reload.lock_version
          assert_includes @customer.name, "0.1"
        end
      end
    end
  end
end
