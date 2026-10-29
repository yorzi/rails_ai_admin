# frozen_string_literal: true

require "test_helper"
require_relative "../../script/support/disposable_database"

class DisposableDatabaseTest < Minitest::Test
  def test_accepts_the_explicit_disposable_postgres_database
    url = "postgresql://127.0.0.1:55439/raa_host_b_test"
    assert_equal url, DisposableDatabase.validate!(url)
  end

  def test_rejects_query_overrides_and_ambiguous_targets
    [
      "postgresql://127.0.0.1/raa_host_b_test?database=production",
      "postgresql://127.0.0.1/raa_host_b_test?dbname=production",
      "postgresql://127.0.0.1/production",
      "postgresql://127.0.0.1/production%2Ffake_test",
      "postgresql://127.0.0.1/raa_test#fragment",
      "https://127.0.0.1/raa_test"
    ].each { |url| assert_raises(ArgumentError) { DisposableDatabase.validate!(url) } }
  end

  def test_invalid_credentials_are_not_in_the_error_or_cause
    error = assert_raises(ArgumentError) { DisposableDatabase.validate!("postgresql://user:private credential@host/raa_test") }
    refute_includes error.message, "private credential"
    assert_nil error.cause
  end
end
