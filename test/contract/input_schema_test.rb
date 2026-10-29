# frozen_string_literal: true

require "test_helper"
require "json_schemer"

class InputSchemaTest < Minitest::Test
  def test_false_zero_blank_null_and_omission_are_distinct
    schema = RailsAiAdmin::InputSchema.new(TestResource.fields.reject { |f| f.options[:readonly] }, partial: true)
    result = schema.coerce({ "name" => "", "points" => "0", "active" => false })
    assert result.valid?, result.errors.inspect
    assert_equal({ "name" => "", "points" => 0, "active" => false }, result.values)
    assert_empty schema.coerce({}).values
    assert_nil schema.coerce({ "points" => nil }).values["points"]
    refute schema.coerce({ "name" => nil }).valid?
  end

  def test_undeclared_and_nested_values_are_rejected
    schema = RailsAiAdmin::InputSchema.new(TestResource.fields)
    refute schema.coerce({ "tenant_id" => "2" }).valid?
    refute schema.coerce({ "name" => { "sql" => "DROP TABLE" } }).valid?
    refute schema.coerce({ "points" => "1.5" }).valid?
    refute schema.coerce({ "active" => "yes" }).valid?
    refute schema.coerce([]).valid?
  end

  def test_digest_is_stable_and_preserves_semantics
    schema = RailsAiAdmin::InputSchema
    assert_equal schema.digest("a" => 1, "b" => false), schema.digest("b" => false, "a" => 1)
    refute_equal schema.digest({}), schema.digest("a" => nil)
    refute_equal schema.digest("a" => false), schema.digest("a" => nil)
    assert_equal schema.digest("a" => BigDecimal("1.00")), schema.digest("a" => BigDecimal("1.0"))
  end

  def test_date_decimal_enum_and_boolean_contracts
    fields = [
      RailsAiAdmin::Field.new(:day, type: :date, nullable: false),
      RailsAiAdmin::Field.new(:amount, type: :decimal, nullable: false),
      RailsAiAdmin::Field.new(:state, type: :enum, values: %w[pending done]),
      RailsAiAdmin::Field.new(:active, type: :boolean)
    ]
    schema = RailsAiAdmin::InputSchema.new(fields)
    input = { "day" => "2026-10-29", "amount" => "0.10", "state" => "pending", "active" => false }
    assert schema.coerce(input).valid?
    assert JSONSchemer.schema(schema.json_schema).valid?(input)
    refute schema.coerce(input.merge("day" => "2026-02-30")).valid?
    refute schema.coerce(input.merge("amount" => "NaN")).valid?
    refute schema.coerce(input.merge("amount" => 0.1)).valid?
    refute schema.coerce(input.merge("state" => "unknown")).valid?
  end

  def test_timestamps_use_authenticated_time_zone
    schema = RailsAiAdmin::InputSchema.new([ RailsAiAdmin::Field.new(:at, type: :datetime) ])
    local = schema.coerce({ "at" => "2026-10-29T09:30" }, time_zone: "Asia/Shanghai")
    assert_equal Time.utc(2026, 10, 29, 1, 30), local.values["at"]
    refute schema.coerce({ "at" => "tomorrow" }).valid?
  end
end
