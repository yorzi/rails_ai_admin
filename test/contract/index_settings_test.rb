# frozen_string_literal: true

require "test_helper"
require "support/database"
require "support/index_resources"

class IndexSettingsTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
    IndexedCustomerAdmin.validate!
  end

  def declare(&block)
    Class.new(RailsAiAdmin::Resource) do
      model "Customer"
      key :declared_index
      title :name
      fields do
        text :name, sortable: true
        text :secret, hidden: true
        integer :points, index: false, sortable: true
        virtual :label_copy, type: :text, depends_on: [ :name ], compute: "IndexLabelCopy"
      end
      index(&block)
    end
  end

  def query(**options) = RailsAiAdmin::Queries::List.new(context, IndexedCustomerAdmin).call(**options)

  def test_defaults_preserve_existing_index_behavior
    settings = TestResource.index
    assert_nil settings.columns
    assert_nil settings.default_sort
    assert_equal 25, settings.page_size
    assert_equal :none, settings.count
    assert settings.frozen?
    page = RailsAiAdmin::Queries::List.new(context, TestResource).call
    assert_nil page.count
    refute page.count_capped
    assert_nil page.sort
    assert_equal 25, page.page_size
  end

  def test_declarations_are_bounded_and_checked_against_fields
    assert declare { page_size 5 }.validate!, "the fixture itself must be valid"
    [
      proc { columns "name" }, proc { columns :name, :name }, proc { columns(*Array.new(51) { |index| :"c#{index}" }) },
      proc { page_size 0 }, proc { page_size 101 }, proc { page_size "25" }, proc { count :estimated },
      proc { default_sort :name, :sideways }, proc { default_sort "name" }, proc { per_page 10 },
      proc { page_size 10; page_size 20 }
    ].each { |block| assert_raises(RailsAiAdmin::ConfigurationError) { declare(&block) } }
    [ proc { columns :missing }, proc { columns :secret }, proc { columns :points }, proc { default_sort :label_copy },
      proc { default_sort :secret }, proc { default_sort :missing } ].each do |block|
      assert_raises(RailsAiAdmin::ConfigurationError) { declare(&block).validate! }
    end
    resource = declare { columns :label_copy, :name }
    assert_equal %i[label_copy name], resource.validate!.index.columns
    assert resource.index.columns.frozen?
    assert_raises(RailsAiAdmin::ConfigurationError) { IndexedCustomerAdmin.index { page_size 5 } }
  end

  def test_page_size_default_sort_and_bounded_exact_count_follow_current_grants
    names = 23.times.map { |index| "Indexed #{index.to_s.rjust(2, "0")}" }
    names.each { |name| Customer.create!(account_id: 1, name: name) }
    12.times { |index| Customer.create!(account_id: 2, name: "Foreign #{index}") }
    first = query(search: "Indexed")
    assert_equal names.reverse.first(10), first.records.map(&:name)
    assert_equal [ "name", "desc", 10, 23, false ], [ first.sort, first.direction, first.page_size, first.count, first.count_capped ]
    assert_equal names.reverse.drop(20), query(search: "Indexed", page: "3").records.map(&:name)
    explicit = query(search: "Indexed", sort: "name", direction: "asc")
    assert_equal names.first(10), explicit.records.map(&:name)
    assert_equal [ "name", "asc" ], [ explicit.sort, explicit.direction ]
    recovered = query(search: "Indexed", page: "9", recover_empty_page: true)
    assert_equal 3, recovered.number

    TestPolicy.hide_name = true
    ungranted = query
    assert_nil ungranted.sort, "an ungranted default sort is not applied"
    assert_equal Customer.where(account_id: 1).order(:id).limit(10).map(&:id), ungranted.records.map(&:id)
  end

  def test_exact_counts_stop_at_the_limit_inside_the_authorized_relation
    now = Time.current
    rows = Array.new(RailsAiAdmin::Presentation::IndexSettings::COUNT_LIMIT + 5) { |index| { account_id: 1, name: "Bulk #{index}", created_at: now, updated_at: now } }
    Customer.insert_all(rows)
    page = query
    assert_equal 10_000, page.count
    assert page.count_capped
    exact = query(search: "Alice")
    assert_equal [ 1, false ], [ exact.count, exact.count_capped ]
  end

  def test_list_hints_omit_the_granted_default_order_and_projection_only_narrows
    access = RailsAiAdmin::Authorization::Access.new(context, IndexedCustomerAdmin)
    assert_empty RailsAiAdmin::Navigation::ListState.new(access, { sort: "name", direction: "desc" }, strict: true).state
    assert_equal({ "sort" => "name" }, RailsAiAdmin::Navigation::ListState.new(access, { sort: "name", direction: "asc" }, strict: true).state)
    assert_equal({ "name" => "Alice" }, access.project(@customer, view: :index, only: %i[name secret active]))
    assert_equal %i[points name], IndexedCustomerAdmin.index.order(access.fields(:read, view: :index)).map(&:name)
  end
end
