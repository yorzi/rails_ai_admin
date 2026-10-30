# frozen_string_literal: true

require "test_helper"
require "support/database"
require "minitest/mock"

class NavigationTest < Minitest::Test
  include DatabaseHelpers

  def setup = reset_database

  def resource(key, **options)
    Class.new(RailsAiAdmin::Resource) do
      model "NoDomainModelNeeded"
      key key
      title :id
      fields { id :id }
      navigation(**options) unless options.empty?
    end
  end

  def menu(resources, actor: 1, current: nil)
    RailsAiAdmin::Navigation::Menu.build(context: context(actor: actor), resources: resources, current_key: current)
  end

  def test_settings_are_bounded_immutable_copies_and_inheritance_has_its_own_defaults
    group, label, icon = String.new("商务"), String.new("Orders"), String.new("shopping-bag")
    parent = resource(:orders, group: group, label: label, icon: icon, order: -5)
    group << " changed"
    label << " changed"
    icon << " changed"
    settings = parent.navigation
    assert_equal [ "商务", "Orders", "shopping-bag", -5, false ], settings.to_h.values
    assert settings.frozen?
    assert settings.group.frozen?
    refute group.frozen?
    assert_nil Class.new(parent).navigation.group
    parent.navigation false
    assert parent.navigation.hidden
  end

  def test_invalid_metadata_and_unsupported_options_fail_closed
    [ { label: "" }, { group: "\nprivate" }, { label: "x" * 81 }, { group: [] },
      { label: "bad\x00" }, { label: "\xff".dup.force_encoding(Encoding::UTF_8) },
      { label: "订单".encode(Encoding::UTF_16LE) }, { icon: "<svg onload=x>" },
      { icon: :users }, { order: "1" }, { order: 1001 }, { hidden: nil }, { url: "/outside" },
      { label: -> { "dynamic" } } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError) { resource(:orders, **options) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { resource(:orders).navigation false, label: "Mixed" }
  end

  def test_denied_entries_do_not_read_metadata_or_create_groups_and_hidden_is_not_a_grant
    denied = resource(:denied)
    denied.define_singleton_method(:navigation) { raise "Denied metadata must not be evaluated" }
    hidden = resource(:hidden, group: "Hidden group", hidden: true)
    visible = resource(:customers, group: "Visible group")
    adapter = TestPolicy.new
    adapter.define_singleton_method(:allowed?) { |context:, action:, resource:, record: nil| resource.key != :denied }
    TestPolicy.stub(:new, adapter) do
      assert_equal [ "Visible group" ], menu([ denied, hidden, visible ]).map(&:label)
      assert RailsAiAdmin::Authorization::Access.new(context, hidden).authorize!(:index)
    end
  end

  def test_order_uses_visible_entry_priority_then_registration_order_and_groups_stay_contiguous
    resources = [ resource(:one, group: "A", order: 5), resource(:two, group: "B", order: -2),
      resource(:three, group: "A", order: -2), resource(:four), resource(:five, group: "A", order: 5) ]
    groups = menu(resources, current: :three)
    assert_equal [ "B", "A", nil ], groups.map(&:label)
    assert_equal [ [ "two" ], %w[three one five], [ "four" ] ], groups.map { |group| group.entries.map(&:key) }
    assert groups[1].entries.first.current
    refute groups.first.entries.first.current
    assert groups.frozen?
    assert groups[1].entries.frozen?
    assert groups[1].entries.first.label.frozen?
  end

  def test_fallback_resource_label_is_bounded_plain_text_and_no_domain_query_is_performed
    item = resource(:orders)
    item.label "<b>Orders</b>".html_safe
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    entry = menu([ item ]).first.entries.first
    assert_equal "<b>Orders</b>", entry.label
    assert_instance_of String, entry.label
    refute entry.label.html_safe?
    assert_empty queries
    item.label "x" * 81
    assert_raises(RailsAiAdmin::ConfigurationError) { menu([ item ]) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_registration_rejects_an_unusable_fallback_menu_label_before_any_request
    assert_raises(RailsAiAdmin::ConfigurationError) { resource(:orders).tap { |item| item.label "x" * 81 }.validate! }
    assert_raises(RailsAiAdmin::ConfigurationError) { resource(:orders).tap { |item| item.label "Line\nbreak" }.validate! }
    assert resource(:orders, label: "Orders").tap { |item| item.label "x" * 81 }.validate!
    assert resource(:orders, hidden: true).tap { |item| item.label "x" * 81 }.validate!
  end

  def test_current_authority_is_rechecked_instead_of_caching_a_menu_between_calls
    item = resource(:orders)
    assert_equal [ "orders" ], menu([ item ]).flat_map(&:entries).map(&:key)
    TestPolicy.denied = true
    assert_empty menu([ item ])
    error = assert_raises(RailsAiAdmin::AccessDenied) { RailsAiAdmin::Navigation::Menu.build(context: nil, resources: []) }
    assert_equal "UNAUTHENTICATED", error.code
  end

  def test_cosmetic_navigation_change_does_not_invalidate_an_original_write_intent
    runner = RailsAiAdmin::Operations::Runner.new
    intent = runner.prepare(context: context, resource: TestResource, operation: :update,
      target_id: @customer.id, expected_version: 0)
    settings = RailsAiAdmin::Navigation::Settings.new(group: "New group", label: "Renamed", icon: "grid", order: -9, hidden: true)
    TestResource.stub(:navigation, settings) do
      result = runner.execute(context: context, intent_ref: intent.id, input: { name: "After cosmetic change" }, human_confirmed: true)
      assert result.success?
      assert_equal "After cosmetic change", @customer.reload.name
      assert_equal 1, @customer.lock_version
    end
  end
end
