# frozen_string_literal: true

require "test_helper"
require "support/database"

class QueryTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
    @query = RailsAiAdmin::Queries::List.new(context, TestResource)
  end

  def test_wildcards_are_literal_on_all_database_adapters
    [ "100% literal", "100_backslash", "100\\anything", "100 normal" ].each { |name| Customer.create!(account_id: 1, name: name) }
    assert_equal [ "100% literal" ], @query.call(search: "100%").records.map(&:name)
    assert_equal [ "100_backslash" ], @query.call(search: "100_").records.map(&:name)
    assert_equal [ "100\\anything" ], @query.call(search: "100\\").records.map(&:name)
  end

  def test_control_search_input_is_rejected_before_database_adapter_serialization
    [ "bad\u0000query", "bad\nquery", "bad\tquery", "x\x7f", String.new("\xff").force_encoding(Encoding::UTF_8), [] ].each do |search|
      error = assert_raises(RailsAiAdmin::AccessDenied) { @query.call(search: search) }
      assert_equal "INVALID_QUERY", error.code
    end
  end

  def test_malformed_page_encodings_and_types_return_the_query_error_contract
    [ String.new("\xff").force_encoding(Encoding::UTF_8), "2".encode(Encoding::UTF_16LE), nil, [] ].each do |page|
      error = assert_raises(RailsAiAdmin::AccessDenied) { @query.call(page: page) }
      assert_equal "INVALID_QUERY", error.code
    end
  end

  def test_search_and_sort_never_bypass_field_policy
    TestPolicy.hide_name = true
    assert_raises(RailsAiAdmin::AccessDenied) { @query.call(search: "Alice") }
    assert_raises(RailsAiAdmin::AccessDenied) { @query.call(sort: "name") }
    assert_raises(RailsAiAdmin::AccessDenied) { @query.call(sort: "secret DESC; DROP TABLE customers") }
    assert_raises(RailsAiAdmin::AccessDenied) { @query.call(page: "100000") }
  end

  def test_pagination_is_bounded_and_scoped
    30.times { |i| Customer.create!(account_id: 1, name: "Customer #{i}") }
    first = @query.call
    second = @query.call(page: "2")
    assert_equal 25, first.records.size
    assert first.has_next
    assert_equal 6, second.records.size
    refute second.has_next
    refute_includes (first.records + second.records).map(&:id), @other.id
    assert_empty first.records.map(&:id) & second.records.map(&:id)
  end
  def test_duplicate_sort_values_use_a_stable_primary_key_tie_breaker_across_pages
    records = 30.times.map { Customer.create!(account_id: 1, name: "Tied") }
    first = @query.call(search: "Tied", sort: "name", direction: "desc")
    second = @query.call(search: "Tied", sort: "name", direction: "desc", page: "2")
    assert_equal records.map(&:id).sort, (first.records + second.records).map(&:id)
    assert_empty first.records.map(&:id) & second.records.map(&:id)
  end

  def test_empty_page_recovery_is_opt_in_and_uses_the_same_scoped_filtered_relation
    expected = 26.times.map { |index| Customer.create!(account_id: 1, name: "Scoped #{index}") }
    30.times { Customer.create!(account_id: 2, name: "Scoped foreign") }
    assert_empty @query.call(search: "Scoped", page: "1000").records
    page = @query.call(search: "Scoped", page: "1000", recover_empty_page: true)
    assert_equal 2, page.number
    assert_equal [ expected.last.id ], page.records.map(&:id)
    page = @query.call(search: "No match", page: "1000", recover_empty_page: true)
    assert_equal 1, page.number
    assert_empty page.records
  end

  def test_limited_scope_cannot_be_overridden_by_list_pagination
    TestPolicy.limited_scope = true
    assert_raises(RailsAiAdmin::ConfigurationError) { @query.call }
  end
end
