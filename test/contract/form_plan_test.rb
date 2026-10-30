# frozen_string_literal: true

require "test_helper"

class FormPlanTest < Minitest::Test
  def field(name, **options) = RailsAiAdmin::Field.new(name, type: :text, **options)

  def test_panels_and_tabs_derive_only_from_supplied_visible_entries
    name = field(:name, tab: "Identity", panel: "Basics")
    points = field(:points, tab: "Account", panel: "Rewards")
    readonly = field(:created_at, readonly: true, tab: "Account", panel: "Metadata")
    plan = RailsAiAdmin::Forms::Plan.new(fields: [ name, points ], values: { "name" => "Alice", "points" => "08" }, readonly_fields: [ readonly ], readonly_values: { "created_at" => "2026-10-30" }, order: [ readonly, name, points ])
    assert plan.tabbed?
    assert_equal [ "Account", "Identity" ], plan.tabs.map(&:label)
    assert_equal [ "Metadata", "Rewards" ], plan.tabs.first.panels.map(&:label)
    assert_equal [ false, true ], plan.tabs.first.panels.flat_map(&:entries).map(&:editable)
    assert_equal "08", plan.entries.find { |entry| entry.field == points }.value
    assert plan.tabs.frozen?
    assert plan.tabs.first.panels.frozen?
    assert plan.entries.first.value.frozen?
  end

  def test_fallback_group_does_not_drop_unassigned_fields_or_false_zero_and_blank
    fields = [ field(:name), RailsAiAdmin::Field.new(:active, type: :boolean, tab: "Account"), RailsAiAdmin::Field.new(:points, type: :integer) ]
    plan = RailsAiAdmin::Forms::Plan.new(fields: fields, values: { "name" => "", "active" => false, "points" => 0 })
    assert_equal [ "Details", "Account" ], plan.tabs.map(&:label)
    assert_equal({ name: "", points: 0, active: false }, plan.entries.to_h { |entry| [ entry.field.name, entry.value ] })
  end

  def test_hidden_fields_never_enter_a_plan_even_if_a_caller_supplies_them
    hidden = field(:secret, hidden: true, tab: "Private tab", panel: "Private panel")
    plan = RailsAiAdmin::Forms::Plan.new(fields: [ hidden ], values: { "secret" => "private" })
    assert_empty plan.entries
    assert_empty plan.tabs
  end

  def test_readonly_values_are_never_taken_from_user_input_and_unlisted_values_are_not_retained
    readonly = field(:name, readonly: true)
    plan = RailsAiAdmin::Forms::Plan.new(fields: [], values: { "name" => "Forged", "secret" => "Never retain" }, readonly_fields: [ readonly ], readonly_values: { "name" => "Current readable value", "secret" => "Never retain" })
    assert_equal "Current readable value", plan.entries.first.value
    refute plan.entries.first.editable
    refute_includes plan.inspect, "Never retain"
  end

  def test_layout_bounds_and_nested_raw_values_fail_closed
    fields = 9.times.map { |index| field("name_#{index}", tab: "Tab #{index}") }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Forms::Plan.new(fields: fields, values: {}) }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Forms::Plan.new(fields: [ field(:name) ], values: { "name" => { nested: "value" } }) }
  end
end
