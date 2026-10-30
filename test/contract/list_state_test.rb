# frozen_string_literal: true

require "test_helper"
require "support/application"

class ListStateTest < Minitest::Test
  include DatabaseHelpers

  class NoIndexPolicy < TestPolicy
    def allowed?(action:, **) = action != :index && super
  end

  def setup
    reset_database
    @access = RailsAiAdmin::Authorization::Access.new(context, TestResource)
  end

  def state(raw = nil, **options) = RailsAiAdmin::Navigation::ListState.new(@access, raw, **options)

  def test_list_hints_have_only_bounded_plain_immutable_query_values
    source = { q: String.new("客户 🚀"), sort: "name", direction: "desc", page: "2" }
    hint = state(source)
    assert_equal({ "q" => "客户 🚀", "sort" => "name", "direction" => "desc", "page" => "2" }, hint.state)
    assert hint.index_allowed?
    refute hint.discarded?
    assert hint.frozen?
    assert hint.state.frozen?
    source[:q] << "changed"
    assert_equal "客户 🚀", hint.state["q"]
    assert_raises(FrozenError) { hint.state["q"] << "changed" }
    assert_empty state({ q: "", sort: "", direction: "asc", page: "1" }).state
  end

  def test_route_or_host_injection_and_malformed_values_are_discarded_without_echo
    [ "https://evil.test", "//evil.test", [], { host: "evil.test" }, { controller: "sessions" }, { resource: "other" }, { q: [ "nested" ] }, { sort: "name DESC" }, { page: "0" }, { page: "1001" }, { direction: "up" }, { q: "x" * 201 }, { q: "bad\u0000query" } ].each do |raw|
      hint = state(raw)
      assert_empty hint.state
      assert hint.discarded?
      assert_raises(RailsAiAdmin::AccessDenied) { state(raw, strict: true) }
    end
  end

  def test_search_sort_grants_are_fresh_and_dropped_settings_reset_the_page
    TestPolicy.hide_name = true
    hint = state({ q: "Alice", sort: "name", direction: "desc", page: "2" })
    assert_empty hint.state
    assert hint.discarded?
    assert hint.index_allowed?
  end

  def test_missing_index_grant_does_not_turn_a_member_hint_into_list_authority
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "ListStateTest::NoIndexPolicy"
    RailsAiAdmin.stub(:configuration, config) do
      access = RailsAiAdmin::Authorization::Access.new(context, TestResource)
      hint = RailsAiAdmin::Navigation::ListState.new(access, { q: "Alice" })
      refute hint.index_allowed?
      assert hint.discarded?
      assert_empty hint.state
      assert access.authorize!(:show, @customer)
    end
  end

  def test_unicode_survives_an_ascii_only_bounded_recovery_header
    hint = state({ q: "客户 🚀", sort: "name", direction: "desc", page: "2" })
    assert hint.encoded.ascii_only?
    assert_equal hint.state, RailsAiAdmin::Navigation::ListState.from_header(@access, hint.encoded).state
    bad = [ "!bad!", "a" * 2049, Base64.urlsafe_encode64('"not a map"'), Base64.urlsafe_encode64("\xff"), Base64.urlsafe_encode64(" " * 1025), Base64.urlsafe_encode64('{"host":"evil.test"}') ]
    bad.each do |header|
      parsed = RailsAiAdmin::Navigation::ListState.from_header(@access, header)
      assert_empty parsed.state
      assert parsed.discarded?
    end
    assert_empty RailsAiAdmin::Navigation::ListState.from_header(@access, nil).state
  end
end
