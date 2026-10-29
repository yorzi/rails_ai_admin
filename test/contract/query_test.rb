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
  def test_limited_scope_cannot_be_overridden_by_list_pagination
    TestPolicy.limited_scope = true
    assert_raises(RailsAiAdmin::ConfigurationError) { @query.call }
  end
end
