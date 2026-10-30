# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class ComputedFieldsTest < Minitest::Test
  include DatabaseHelpers

  class Summary < RailsAiAdmin::Fields::Computation
    version "1"
    class_attribute :calls, default: 0
    def call(values, field:, time_zone:)
      self.class.calls += 1
      "#{values.fetch('name')}: #{values.fetch('points')} points"
    end
  end
  class Wrapped < RailsAiAdmin::Fields::Computation
    def call(values, **) = "[#{values.fetch('summary')}]"
  end
  class Mutating < RailsAiAdmin::Fields::Computation
    def call(values, **) = values.fetch("name").replace("Mutation")
  end
  class Writing < RailsAiAdmin::Fields::Computation
    def call(values, **)
      Customer.delete_all
      values.fetch("name")
    end
  end
  class Invalid < RailsAiAdmin::Fields::Computation
    def call(_values, **) = { unauthorized: "object" }
  end
  class Failure < RailsAiAdmin::Fields::Computation
    def call(_values, **) = raise(ArgumentError, "private error content")
  end
  class Snapshot < RailsAiAdmin::Fields::Computation
    class_attribute :observed
    def call(values, **)
      self.class.observed = values
      values.fetch("name")
    end
  end
  class Large < RailsAiAdmin::Fields::Computation
    def call(_values, **) = "x" * 16_000
  end
  class Budget < RailsAiAdmin::Fields::Computation
    class_attribute :now, default: 0.0
    def call(values, **)
      self.class.now += 2
      values.fetch("name")
    end
  end
  class Resource < RailsAiAdmin::Resource
    model "Customer"
    key :computed_customers
    title :wrapped
    fields do
      id :id
      text :name
      integer :points
      virtual :summary, type: :text, depends_on: %i[name points], compute: "ComputedFieldsTest::Summary"
      virtual :wrapped, type: :text, depends_on: [ :summary ], compute: "ComputedFieldsTest::Wrapped"
    end
  end
  class Policy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      grants = super
      grants + %i[summary wrapped]
    end
    def select_records?(**) = true
  end

  class AllFieldsPolicy < Policy
    def fields(context:, resource:, action:, record: nil) = resource.fields.map(&:name)
  end

  def setup
    reset_database
    Summary.calls = 0
  end

  def with_access(resource = Resource)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "ComputedFieldsTest::Policy"
    RailsAiAdmin.stub(:configuration, config) { yield RailsAiAdmin::Authorization::Access.new(context, resource) }
  end

  def resource_for(&block)
    klass = Class.new(RailsAiAdmin::Resource)
    klass.model "Customer"
    klass.key :test_computation
    klass.title :name
    klass.fields { text :name }
    klass.fields(&block)
    klass
  end

  def test_dependency_projection_is_readonly_typed_and_resolved_once
    Resource.validate!
    with_access do |access|
      values = access.project(@customer)
      assert_equal "Alice: 0 points", values.fetch("summary")
      assert_equal "[Alice: 0 points]", values.fetch("wrapped")
      assert_equal 1, Summary.calls
      assert_equal %i[name points], access.fields(:write, @customer).map(&:name)
      assert_empty access.fields(:search, @customer)
      assert_empty access.fields(:sort, @customer)
      refute Resource.fields.find { |field| field.name == :summary }.writable?(:update)
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_any_recursive_dependency_denial_hides_computation_before_invocation
    with_access do |access|
      TestPolicy.hide_name = true
      @customer.define_singleton_method(:name) { raise "Denied getter must never run" }
      values = access.project(@customer)
      refute values.key?("summary")
      refute values.key?("wrapped")
      assert_equal 0, Summary.calls
      assert_raises(RailsAiAdmin::AccessDenied) { access.read_value(@customer, Resource.fields.find { |field| field.name == :wrapped }) }
      controller = RailsAiAdmin::ApplicationController.new
      controller.instance_variable_set(:@context, context)
      assert_equal "Record ##{@customer.id}", controller.send(:record_label, Resource, @customer)
      assert_equal 0, Summary.calls
    end
  end

  def test_physical_dependency_getters_cannot_write_before_the_computation_cache
    @customer.define_singleton_method(:name) do
      Customer.where(id: id).update_all(points: 77)
      "Alice"
    end
    with_access do |access|
      assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) }
      assert_equal 0, @customer.reload.points
      physical = Resource.fields.find { |field| field.name == :name }
      assert_raises(RailsAiAdmin::ConfigurationError) { access.read_value(@customer, physical) }
      assert_equal 0, @customer.reload.points
    end
  end

  def test_registered_classes_are_fresh_and_version_mismatch_fails_closed
    field = Resource.fields.find { |entry| entry.name == :summary }
    original = Summary.version
    Summary.version "2"
    with_access { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
    replacement = RailsAiAdmin::Resource::FieldBuilder.new({}).virtual(:summary, type: :text, depends_on: %i[name points], compute: "ComputedFieldsTest::Summary")
    refute_equal field.contract, replacement.contract
  ensure
    Summary.version original
  end

  def test_dependency_graph_boot_does_not_consult_domain_schema_and_diamond_reads_once
    Customer.stub(:columns_hash, -> { raise "Domain schema consulted during registration" }) { Resource.validate! }
    klass = resource_for do
      integer :points
      virtual :summary, type: :text, depends_on: %i[name points], compute: "ComputedFieldsTest::Summary"
      virtual :left, type: :text, depends_on: [ :summary ], compute: "ComputedFieldsTest::Wrapped"
      virtual :right, type: :text, depends_on: [ :summary ], compute: "ComputedFieldsTest::Wrapped"
    end
    klass.validate!
    reads = 0
    @customer.define_singleton_method(:name) { reads += 1; "Alice" }
    Policy.stub(:new, AllFieldsPolicy.new) do
      with_access(klass) do |access|
        values = access.project(@customer)
        assert_equal "[Alice: 0 points]", values.fetch("left")
        assert_equal values.fetch("left"), values.fetch("right")
      end
    end
    assert_equal 1, Summary.calls
    assert_equal 1, reads
  end

  def test_dependency_schema_rejects_missing_cyclic_and_widening_declarations
    assert_raises(RailsAiAdmin::ConfigurationError) do
      resource_for { virtual :summary, type: :text, depends_on: [ :missing ], compute: "ComputedFieldsTest::Summary" }.validate!
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      resource_for do
        virtual :summary, type: :text, depends_on: [ :wrapped ], compute: "ComputedFieldsTest::Summary"
        virtual :wrapped, type: :text, depends_on: [ :summary ], compute: "ComputedFieldsTest::Wrapped"
      end.validate!
    end
    [ [], [ :name, :name ], [ :destroy ], [ "name", :name ] ].each do |dependencies|
      assert_raises(RailsAiAdmin::ConfigurationError) do
        resource_for { virtual :summary, type: :text, depends_on: dependencies, compute: "ComputedFieldsTest::Summary" }.validate!
      end
    end
    [ { readonly: false }, { searchable: :prefix }, { sortable: true }, { create: true }, { edit: true } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError) do
        resource_for { virtual :summary, type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::Summary", **options }.validate!
      end
    end
  end

  def test_mutation_writes_bad_output_and_errors_are_scrubbed_configuration_failures
    %w[Mutating Writing Invalid Failure].each do |type|
      klass = resource_for { virtual :summary, type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::#{type}" }
      klass.validate!
      with_access(klass) do |access|
        error = assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) }
        refute_includes error.message, "private error"
        assert_equal "Alice", @customer.reload.name
        assert_equal 2, Customer.count
      end
    end
  end

  def test_nonattribute_dependencies_do_not_enable_model_method_calls
    klass = resource_for do
      text :destroy
      virtual :summary, type: :text, depends_on: [ :destroy ], compute: "ComputedFieldsTest::Summary"
    end
    klass.validate!
    policy = Class.new(Policy) { def fields(**) = %i[name destroy summary] }
    Policy.stub(:new, policy.new) do
      with_access(klass) { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
    end
    assert Customer.exists?(@customer.id)
  end

  def test_dependency_snapshots_preserve_only_declared_scalars_without_freezing_the_record
    @customer.update!(active: false)
    original = @customer.created_at.in_time_zone("Asia/Shanghai")
    @customer.define_singleton_method(:created_at) { original }
    klass = resource_for do
      id :id
      integer :points
      boolean :active
      datetime :created_at
      text :secret
      virtual :summary, type: :text, depends_on: %i[id name points active created_at], compute: "ComputedFieldsTest::Snapshot"
    end
    klass.validate!
    Policy.stub(:new, AllFieldsPolicy.new) do
      with_access(klass) { |access| assert_equal "Alice", access.project(@customer).fetch("summary") }
    end
    snapshot = Snapshot.observed
    assert_equal %w[active created_at id name points], snapshot.keys.sort
    refute snapshot.key?("secret")
    assert_equal @customer.id, snapshot.fetch("id")
    assert_equal 0, snapshot.fetch("points")
    assert_equal false, snapshot.fetch("active")
    assert snapshot.frozen?
    assert snapshot.fetch("name").frozen?
    assert snapshot.fetch("created_at").utc?
    assert snapshot.fetch("created_at").frozen?
    refute original.frozen?
    assert_equal 28_800, original.utc_offset
    assert_raises(FrozenError) { snapshot.fetch("created_at").localtime }
    assert_equal "Alice", @customer.name
    [ nil, BigDecimal("0.10"), Date.new(2026, 10, 30) ].each do |scalar|
      @customer.stub(:points, scalar) do
        Policy.stub(:new, AllFieldsPolicy.new) { with_access(klass) { |access| access.project(@customer) } }
      end
      scalar.nil? ? assert_nil(Snapshot.observed.fetch("points")) : assert_equal(scalar, Snapshot.observed.fetch("points"))
    end
    # Unknown objects are rejected instead of being stringified into a snapshot.
    @customer.stub(:points, @customer) do
      Policy.stub(:new, AllFieldsPolicy.new) do
        with_access(klass) { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
      end
    end
  end

  def test_graph_depth_and_projection_budget_bounds
    make_chain = lambda do |count|
      resource_for do
        count.times do |index|
          virtual "v#{index}", type: :text, depends_on: [ index.zero? ? :name : "v#{index - 1}" ], compute: "ComputedFieldsTest::Snapshot"
        end
      end
    end
    make_chain.call(8).validate!
    assert_raises(RailsAiAdmin::ConfigurationError) { make_chain.call(9).validate! }
    too_many = resource_for do
      128.times { |index| virtual "v#{index}", type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::Snapshot" }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { too_many.validate! }
    large = resource_for do
      5.times { |index| virtual "v#{index}", type: :text, max_length: 16_384, depends_on: [ :name ], compute: "ComputedFieldsTest::Large" }
    end
    Policy.stub(:new, AllFieldsPolicy.new) do
      with_access(large) { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
    end
    slow = resource_for { virtual :summary, type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::Budget" }
    Budget.now = 0.0
    Process.stub(:clock_gettime, ->(*) { Budget.now }) do
      with_access(slow) { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
    end
  end

  def test_projection_budget_includes_physical_reads_after_the_last_computation
    klass = resource_for do
      virtual :summary, type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::Snapshot"
      integer :points
    end
    @customer.define_singleton_method(:points) { Budget.now += 2; 0 }
    Budget.now = 0.0
    Process.stub(:clock_gettime, ->(*) { Budget.now }) do
      with_access(klass) { |access| assert_raises(RailsAiAdmin::ConfigurationError) { access.project(@customer) } }
    end
  end

  def test_computed_fields_cannot_be_operation_or_work_inputs
    [ RailsAiAdmin::Operation, RailsAiAdmin::Work ].each do |base|
      operation = Class.new(base)
      operation.description "Forbidden computed input"
      operation.input { virtual :summary, type: :text, depends_on: [ :name ], compute: "ComputedFieldsTest::Summary" }
      operation.define_method(:perform) { |*| }
      assert_raises(RailsAiAdmin::ConfigurationError) { operation.validate! }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::InputSchema.new(Resource.fields) }
  end
end
