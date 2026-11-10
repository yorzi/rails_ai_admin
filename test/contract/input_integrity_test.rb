# frozen_string_literal: true

require "test_helper"
require "support/database"

# Regression tests for the input-integrity findings of the 2026-11-10 audit.
class InputIntegrityTest < Minitest::Test
  include DatabaseHelpers

  class PaymentResource < RailsAiAdmin::Resource
    model "Payment"
    key :integrity_payments
    title :reference
    fields do
      id :id
      text :reference
      textarea :note
      decimal :amount
      datetime :paid_at
    end
  end

  def setup = reset_database

  def field(name) = PaymentResource.fields.find { |entry| entry.name == name }

  def error_for(field, value)
    field.coerce(value)
    nil
  rescue ArgumentError => error
    error.message
  end

  def test_raa_002_blank_text_is_null_for_a_nullable_field
    assert_nil field(:reference).coerce("")
    assert_nil field(:reference).coerce("   ")
    assert_nil field(:note).coerce("\r\n\t ")
    # Non-blank text is stored exactly as typed; it is never trimmed.
    assert_equal " a ", field(:reference).coerce(" a ")
    # Host code (computations, previews) keeps the scalar-only rule.
    assert_equal "", field(:reference).coerce_output("")
  end

  def test_raa_003_required_or_non_null_text_rejects_blank_and_whitespace
    required = RailsAiAdmin::Field.new(:code, type: :text, required: true)
    non_null = RailsAiAdmin::Field.new(:code, type: :text, nullable: false)
    both = RailsAiAdmin::Field.new(:code, type: :textarea, required: true, nullable: false)
    [ required, non_null, both ].each do |declared|
      [ "", "  ", " \t" ].each { |blank| assert_equal "cannot be blank", error_for(declared, blank), "#{declared.options} #{blank.inspect}" }
      assert_equal "x", declared.coerce("x")
    end
    assert_equal "cannot be blank", error_for(required, nil)
    assert_equal "cannot be blank", error_for(RailsAiAdmin::Field.new(:points, type: :integer, required: true), "")
    result = RailsAiAdmin::InputSchema.new([ required ]).coerce({ "code" => " " })
    assert_equal [ "cannot be blank" ], result.errors["code"]
  end

  def test_raa_004_decimal_input_respects_column_precision_and_scale
    amount = field(:amount)
    assert_equal({ precision: 8, scale: 2 }, amount.decimal_limits)
    assert_equal "must have at most 2 decimal places", error_for(amount, "1234.567")
    assert_equal "is out of range", error_for(amount, "99999999.99")
    assert_equal "is out of range", error_for(amount, "1" * 60)
    assert_equal "is out of range", error_for(amount, "1" * 101)
    assert_equal BigDecimal("999999.99"), amount.coerce("999999.99")
    assert_equal BigDecimal("-999999.99"), amount.coerce("-999999.99")
    # Trailing zeros are not extra precision.
    assert_equal BigDecimal("1234.5"), amount.coerce("1234.500")
    assert_equal BigDecimal("0.05"), amount.coerce(".05")
  end

  def test_raa_004_explicit_precision_and_scale_publish_a_matching_schema
    declared = RailsAiAdmin::Field.new(:rate, type: :decimal, precision: 5, scale: 1, nullable: false)
    assert_equal({ precision: 5, scale: 1 }, declared.decimal_limits)
    assert_equal BigDecimal("1234.5"), declared.coerce("1234.5")
    assert_equal "is out of range", error_for(declared, "12345.6")
    assert_equal "must have at most 1 decimal places", error_for(declared, "1.25")
    schema = JSONSchemer.schema(declared.json_schema)
    %w[1234.5 1.0 1.50 0.5 .5 -12 0012.3].each { |value| assert schema.valid?(value), value }
    %w[1.25 12345 12345.6 .25 abc].each { |value| refute schema.valid?(value), value }
    integral = RailsAiAdmin::Field.new(:count, type: :decimal, precision: 3, scale: 0)
    assert integral.coerce("999")
    assert_equal "must have at most 0 decimal places", error_for(integral, "1.5")
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:name, type: :text, scale: 2) }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:rate, type: :decimal, precision: 2, scale: 3) }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:rate, type: :decimal, precision: 0) }
  end

  def test_raa_004_decimals_without_known_limits_keep_accepting_any_scale
    loose = RailsAiAdmin::Field.new(:ratio, type: :decimal)
    assert_empty loose.decimal_limits
    assert_equal BigDecimal("1.23456789"), loose.coerce("1.23456789")
    assert_equal "534.8", loose.format(BigDecimal("534.8"))
  end

  def test_raa_004_decimal_input_is_rejected_before_the_database_rounds_it
    Payment.create!(account_id: 1, amount: "1.00")
    result = RailsAiAdmin::InputSchema.new([ field(:amount) ]).coerce({ "amount" => "1234.567" })
    assert_equal [ "must have at most 2 decimal places" ], result.errors["amount"]
    # The database itself would silently round (SQLite) or reject (PostgreSQL).
    stored = Payment.create!(account_id: 1, amount: field(:amount).coerce("1234.56"))
    assert_equal BigDecimal("1234.56"), stored.reload.amount
  end

  def test_raa_014_decimal_display_uses_the_scale_without_rounding
    amount = field(:amount)
    assert_equal "534.80", amount.format(BigDecimal("534.8"))
    assert_equal "10.50", amount.format(BigDecimal("10.5"))
    assert_equal "0.00", amount.format(BigDecimal("0"))
    assert_equal "-3.00", amount.format(BigDecimal("-3"))
    assert_equal "1.234", amount.format(BigDecimal("1.234"))
    assert_equal "7", RailsAiAdmin::Field.new(:count, type: :decimal, scale: 0).format(BigDecimal("7"))
  end

  def test_raa_010_impossible_calendar_dates_and_times_are_rejected
    paid_at = field(:paid_at)
    %w[2026-02-30T10:00 2026-04-31T00:00 2026-02-29T12:00 2026-13-01T00:00 2026-01-01T24:00
      2026-01-01T10:60 2026-01-01T10:00:60 2026-01-01T10:00+24:00].each do |value|
      assert_equal "is not a valid date and time", error_for(paid_at, value), value
    end
    assert_equal Time.utc(2028, 2, 29, 12), paid_at.coerce("2028-02-29T12:00")
    assert_equal Time.utc(2026, 4, 30, 23, 59, 59), paid_at.coerce("2026-04-30T23:59:59Z")
    assert_equal Time.utc(2026, 1, 1, 2), paid_at.coerce("2026-01-01T10:00+08:00")
    assert_equal Time.utc(2026, 3, 1, 1), paid_at.coerce("2026-03-01T10:00", time_zone: "Asia/Tokyo")
    assert_equal "is invalid", error_for(RailsAiAdmin::Field.new(:on, type: :date), "2026-02-30")
  end

  def test_raa_016_control_characters_are_rejected_in_text_input
    reference, note = field(:reference), field(:note)
    [ "a\u0000b", "a\tb", "a\nb", "a\u001Bb", "a\u007Fb" ].each do |value|
      assert_equal "contains control characters", error_for(reference, value), value.inspect
    end
    [ "a\u0000b", "a\u0007b", "a\u000Bb", "a\u007Fb" ].each do |value|
      assert_equal "contains control characters", error_for(note, value), value.inspect
    end
    assert_equal "line one\r\nline\ttwo\n", note.coerce("line one\r\nline\ttwo\n")
    assert_equal "Zoë Müller — ok", reference.coerce("Zoë Müller — ok")
  end

  def test_raa_016_a_nul_byte_never_reaches_the_database
    result = RailsAiAdmin::InputSchema.new([ field(:reference), field(:note) ]).coerce({ "reference" => "a\u0000b", "note" => "x\u0000" })
    assert_equal [ "contains control characters" ], result.errors["reference"]
    assert_equal [ "contains control characters" ], result.errors["note"]
    assert_equal 0, Payment.count
  end
end
