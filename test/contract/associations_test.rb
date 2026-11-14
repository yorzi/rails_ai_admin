# frozen_string_literal: true

require "test_helper"
require "support/database"
require "support/associations"
require "rails_ai_admin/doctor"

class AssociationsContractTest < Minitest::Test
  include DatabaseHelpers
  include AssociationFixtures

  Field = RailsAiAdmin::Field
  Association = RailsAiAdmin::Fields::Association

  def setup
    reset_database
    AssociationFixtures::Policy.reset!
    @runner = RailsAiAdmin::Operations::Runner.new
  end

  def create_invoice(customer_id, context: self.context, number: "INV-1")
    intent = @runner.prepare(context: context, resource: @invoices, operation: :create)
    @runner.execute(context: context, intent_ref: intent.id, input: { "number" => number, "customer" => customer_id&.to_s }, human_confirmed: true)
  end

  def update_invoice(invoice, input)
    intent = @runner.prepare(context: context, resource: @invoices, operation: :update, target_id: invoice.id, expected_version: invoice.lock_version)
    @runner.execute(context: context, intent_ref: intent.id, input: input, human_confirmed: true)
  end

  def test_belongs_to_declares_a_reference_contract_on_its_foreign_key
    field = Field.new(:customer, type: :belongs_to)
    assert_equal "customer_id", field.column
    assert_equal :customers, field.options[:resource]
    assert_equal "Customer", field.label
    assert_equal "client_ref", Field.new(:client, type: :belongs_to, resource: :customers, foreign_key: "client_ref").column
    assert_equal "name", Field.new(:name, type: :text).column
    assert_equal %i[eq], Field.new(:customer, type: :belongs_to, filterable: true).filter_operators
    assert_equal "7", field.coerce(7)
    assert_equal "7", field.coerce("7")
    assert_equal "3f0e2d1c-aaaa-4bbb-8ccc-1234567890ab", field.coerce("3f0e2d1c-aaaa-4bbb-8ccc-1234567890ab")
    assert_nil field.coerce("")
    assert_nil field.coerce(nil)
    [ -1, 0, "../7", "7 OR 1=1", "a" * 101, 1.5, [ "7" ], { "id" => "7" } ].each do |value|
      error = assert_raises(ArgumentError) { field.coerce(value) }
      assert_equal "is not an available choice", error.message
    end
    assert_raises(ArgumentError) { Field.new(:customer, type: :belongs_to, nullable: false).coerce("") }
    assert_equal({ "anyOf" => [ { "type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$" }, { "type" => "null" } ] }, field.json_schema)
  end

  def test_belongs_to_options_are_closed_and_bounded
    [ { resource: "Customers" }, { resource: :"bad key" },
      { foreign_key: "customer" }, { foreign_key: "customer_id; drop" }, { foreign_key: :customer_id } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError, options.inspect) { Field.new(:customer, type: :belongs_to, **options) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { Field.new(:name, type: :text, resource: :customers) }
    assert_raises(RailsAiAdmin::ConfigurationError) { Field.new(:name, type: :integer, foreign_key: "customer_id") }
    plugin = Class.new(RailsAiAdmin::Fields::Type) do
      def self.name = "ReferencePlugin"
      scalar :belongs_to
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { plugin.metadata }
  end

  def test_registry_requires_registered_targets_and_has_many_back_references
    error = assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Registry.new([ "AssociationFixtures::InvoiceAdmin" ]) }
    assert_match(/unregistered resource customers/, error.message)
    error = assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Registry.new([ "AssociationFixtures::CustomerAdmin" ]) }
    assert_match(/has_many invoices/, error.message)
    assert_raises(RailsAiAdmin::ConfigurationError) { Class.new(RailsAiAdmin::Resource) { has_many :invoices, limit: 0 } }
    assert_raises(RailsAiAdmin::ConfigurationError) { Class.new(RailsAiAdmin::Resource) { has_many :invoices, label: "x" * 81 } }
    assert_raises(RailsAiAdmin::ConfigurationError) do
      Class.new(RailsAiAdmin::Resource) do
        has_many :invoices
        has_many :invoices
      end
    end
  end

  def test_declarations_must_match_the_model_reflection
    with_association_resources do |registry|
      assert_equal registry.fetch(:customers), Association.validate!(invoice_admin(registry), customer_field(registry), registry: registry)
      mismatched = Class.new(RailsAiAdmin::Resource) do
        model "Invoice"
        key :wrong_invoices
        title :number
        fields do
          text :number
          belongs_to :customer, foreign_key: "account_id"
        end
      end
      field = mismatched.fields.last
      error = assert_raises(RailsAiAdmin::ConfigurationError) { Association.validate!(mismatched, field, registry: registry) }
      assert_match(/account_id/, error.message)
      missing = Field.new(:owner, type: :belongs_to, resource: :customers)
      assert_raises(RailsAiAdmin::ConfigurationError) { Association.validate!(invoice_admin(registry), missing, registry: registry) }
    end
  end

  def test_references_resolve_in_one_query_and_hide_unavailable_targets_identically
    second = Customer.create!(account_id: 1, name: "Bob")
    with_association_resources do |registry|
      resolver = Association.new(context, invoice_admin(registry))
      field = customer_field(registry)
      ids = [ @customer.id, second.id, @other.id, 999_999, @customer.id ]
      queries = count_queries { resolver.prime(field, ids) }
      assert_equal 1, queries
      assert_equal 0, count_queries { resolver.reference(field, second.id) }
      alice = resolver.reference(field, @customer.id)
      assert alice.visible
      assert_equal [ "Alice", :customers, @customer.id.to_s ], [ alice.label, alice.resource_key, alice.id ]
      foreign, missing = resolver.reference(field, @other.id), resolver.reference(field, 999_999)
      assert_equal [ false, nil, "Customer ##{@other.id}" ], [ foreign.visible, foreign.resource_key, foreign.label ]
      assert_equal [ false, nil, "Customer #999999" ], [ missing.visible, missing.resource_key, missing.label ]
      assert_equal 0, count_queries { resolver.prime(field, [ "not-a-number", "99999999999999999999" ]) }
      refute resolver.admissible?(field, "not-a-number")

      AssociationFixtures::Policy.deny_customer_show = true
      denied = Association.new(context, invoice_admin(registry)).reference(field, @customer.id)
      assert_equal [ false, "Customer ##{@customer.id}" ], [ denied.visible, denied.label ]
    end
  end

  def test_picker_search_returns_only_what_the_target_index_would_show
    aaron = Customer.create!(account_id: 1, name: "Aaron")
    Customer.create!(account_id: 2, name: "Aaron other tenant")
    with_association_resources do |registry|
      customers = registry.fetch(:customers)
      assert_equal [ [ "Aaron", aaron.id.to_s ] ], Association.search(context, customers, "aron")
      assert_equal [ "Alice" ], Association.search(context, customers, @customer.id.to_s).map(&:first)
      assert_empty Association.search(context, customers, @other.id.to_s), "another tenant's key is not a match"
      assert_empty Association.search(context, customers, "  ")
      assert_raises(RailsAiAdmin::AccessDenied) { Association.search(context, customers, "x" * 201) }

      AssociationFixtures::Policy.hidden_customers = [ "Aaron" ]
      assert_empty Association.search(context, customers, "aron")

      AssociationFixtures::Policy.hidden_customers = []
      AssociationFixtures::Policy.deny_customer_show = true
      assert_empty Association.search(context, customers, "a"), "records without a show grant are left out"

      AssociationFixtures::Policy.deny_customer_show = false
      AssociationFixtures::Policy.customer_search = []
      assert_equal [ "Aaron" ], Association.search(context, customers, aaron.id.to_s).map(&:first), "an unsearchable target still matches its key"
      assert_empty Association.search(context, customers, "Aaron")

      AssociationFixtures::Policy.deny_customer_index = true
      assert_raises(RailsAiAdmin::AccessDenied) { Association.search(context, customers, "Aaron") }
    end
  end

  def test_choices_are_bounded_current_and_ordered_by_a_granted_title
    Customer.create!(account_id: 1, name: "Aaron")
    with_association_resources do |registry|
      field = customer_field(registry)
      choices = Association.new(context, invoice_admin(registry)).choices(field)
      assert choices.complete
      assert_equal %w[Aaron Alice], choices.options.map(&:first)
      refute_includes choices.options.map(&:first), "Other tenant"

      AssociationFixtures::Policy.customer_sort = []
      unordered = Association.new(context, invoice_admin(registry)).choices(field)
      assert_equal [ "Alice", "Aaron" ], unordered.options.map(&:first)

      AssociationFixtures::Policy.deny_customer_index = true
      closed = Association.new(context, invoice_admin(registry)).choices(field)
      refute closed.complete
      assert_empty closed.options

      AssociationFixtures::Policy.deny_customer_index = false
      Customer.insert_all(Array.new(Association::MAX_CHOICES) { |index| { account_id: 1, name: "Bulk #{index}", lock_version: 0, created_at: Time.current, updated_at: Time.current } })
      large = Association.new(context, invoice_admin(registry)).choices(field)
      refute large.complete
      assert_equal Association::MAX_CHOICES, large.options.size
    end
  end

  def test_writes_accept_only_currently_visible_targets
    with_association_resources do |registry|
      @invoices = invoice_admin(registry)
      result = create_invoice(@customer.id)
      assert result.success?, result.inspect
      invoice = Invoice.find(result.record_id)
      assert_equal @customer.id, invoice.customer_id
      assert_equal @customer.id.to_s, result.values["customer"]
      assert_equal %w[number customer].sort, RailsAiAdmin::AuditEvent.find(result.audit_ref).changed_fields.sort

      [ @other.id, 999_999, "not-a-key" ].each do |target|
        rejected = create_invoice(target, number: "INV-#{target}")
        assert_equal "VALIDATION_FAILED", rejected.code
        assert_equal({ "customer" => [ "is not an available choice" ] }, rejected.errors)
      end
      assert_equal 1, Invoice.count

      AssociationFixtures::Policy.hidden_customers = [ "Alice" ]
      assert_equal({ "customer" => [ "is not an available choice" ] }, create_invoice(@customer.id, number: "INV-hidden").errors)
    end
  end

  def test_updates_keep_or_clear_a_stored_reference_but_never_attach_an_unavailable_one
    second = Customer.create!(account_id: 1, name: "Bob")
    invoice = Invoice.create!(account_id: 1, number: "INV-1", customer: @customer)
    with_association_resources do |registry|
      @invoices = invoice_admin(registry)
      # The actor can no longer see Alice; saving other fields keeps her key.
      AssociationFixtures::Policy.hidden_customers = [ "Alice" ]
      kept = update_invoice(invoice, "number" => "INV-1a", "customer" => @customer.id.to_s)
      assert kept.success?, kept.inspect
      assert_equal [ "INV-1a", @customer.id ], invoice.reload.then { |record| [ record.number, record.customer_id ] }
      assert_equal %w[number], RailsAiAdmin::AuditEvent.find(kept.audit_ref).changed_fields

      reparented = update_invoice(invoice, "customer" => second.id.to_s)
      assert reparented.success?, reparented.inspect
      assert_equal second.id, invoice.reload.customer_id
      assert_equal %w[customer], RailsAiAdmin::AuditEvent.find(reparented.audit_ref).changed_fields

      rejected = update_invoice(invoice, "customer" => @customer.id.to_s)
      assert_equal "VALIDATION_FAILED", rejected.code
      assert_equal second.id, invoice.reload.customer_id

      cleared = update_invoice(invoice, "customer" => "")
      assert cleared.success?, cleared.inspect
      assert_nil invoice.reload.customer_id
    end
  end

  def test_a_target_removed_after_admission_is_a_conflict_not_an_error
    doomed = Customer.create!(account_id: 1, name: "Doomed")
    remove = -> { Customer.where(id: doomed.id).delete_all }
    with_association_resources do |registry|
      @invoices = invoice_admin(registry)
      Invoice.set_callback(:create, :before, remove)
      result = create_invoice(doomed.id)
      assert_equal "CONFLICT", result.code
      assert_equal 0, Invoice.count
      assert Customer.exists?(doomed.id), "the whole transaction rolls back"
    ensure
      Invoice.skip_callback(:create, :before, remove)
    end
  end

  def test_filters_narrow_by_reference_only_with_a_filter_grant
    second = Customer.create!(account_id: 1, name: "Bob")
    mine = Invoice.create!(account_id: 1, number: "INV-A", customer: @customer)
    Invoice.create!(account_id: 1, number: "INV-B", customer: second)
    Invoice.create!(account_id: 2, number: "INV-F", customer: @other)
    with_association_resources do |registry|
      list = RailsAiAdmin::Queries::List.new(context, invoice_admin(registry))
      page = list.call(filters: { "customer" => { "eq" => @customer.id.to_s } })
      assert_equal [ mine.id ], page.records.map(&:id)
      assert_empty list.call(filters: { "customer" => { "eq" => @other.id.to_s } }).records
      %w[gte lte].each do |operator|
        assert_raises(RailsAiAdmin::AccessDenied) { list.call(filters: { "customer" => { operator => "1" } }) }
      end
      assert_raises(RailsAiAdmin::AccessDenied) { list.call(filters: { "customer" => { "eq" => "x y" } }) }
      AssociationFixtures::Policy.invoice_filters = []
      assert_raises(RailsAiAdmin::AccessDenied) { list.call(filters: { "customer" => { "eq" => @customer.id.to_s } }) }
    end
  end

  def test_doctor_reports_association_agreement
    with_association_resources do |registry|
      operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
      doctor = RailsAiAdmin::Doctor.new(configuration: RailsAiAdmin.configuration, registry: registry, application: nil, operation_registry: operations)
      check = doctor.checks.find { |entry| entry.name == "associations:invoices" }
      assert_equal :review, check.status
      assert_match(/1 belongs_to declarations match/, check.message)
      schema = doctor.checks.find { |entry| entry.name == "schema:invoices" }
      assert_equal :ok, schema.status
      refute doctor.checks.any? { |entry| entry.name == "associations:customers" }
    end
  end
end
