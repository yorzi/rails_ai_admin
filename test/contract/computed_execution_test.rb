# frozen_string_literal: true

require "test_helper"
require "support/collections"
require "rails_ai_admin/doctor"

class ComputedExecutionTest < Minitest::Test
  include DatabaseHelpers
  include CollectionContractHelpers

  class HasPoints < RailsAiAdmin::Fields::Computation
    version "1"
    def call(values, **) = values.fetch("points", 0).positive?
  end
  class Resource < RailsAiAdmin::Resource
    model "Customer"
    key :computed_batches
    title :summary
    fields do
      id :id
      text :name
      integer :points
      virtual :summary, type: :boolean, depends_on: [ :points ], compute: "ComputedExecutionTest::HasPoints"
    end
    operation :award, handler: "CollectionContractOperation", scope: :collection
  end
  class Policy < CollectionContractPolicy
    def fields(**) = super + [ :summary ]
  end

  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Second")
  end

  def with_computed
    with_collection(resources: [ "ComputedExecutionTest::Resource" ], policy: "ComputedExecutionTest::Policy") { yield }
  end

  def captured
    RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: Resource, target_ids: [ @customer.id, @second.id ])
  end

  def test_bool_titles_share_formatting_on_pages_selections_jobs_and_current_results
    with_computed do
      access = RailsAiAdmin::Authorization::Access.new(context, Resource)
      assert_equal "No", access.record_label(@customer)
      selection = captured
      assert_equal [ "No", "No" ], selection.targets.map(&:label)
      proposal = RailsAiAdmin::Collections::Runner.new.preflight(context: context, resource: Resource, operation: :award,
        selection_ref: selection.selection_ref, input: { amount: "8", note: "Awarded" })
      admitted = admit(proposal)
      assert admitted.accepted?
      queries = RailsAiAdmin::Collections::Queries.new
      assert_equal [ "No", "No" ], queries.fetch(context: context, job_ref: admitted.job_ref).entries.map(&:label)
      assert_equal "succeeded", RailsAiAdmin::Collections::Dispatcher.new.run(admitted.job_ref).status
      assert_equal [ "Yes", "Yes" ], queries.fetch(context: context, job_ref: admitted.job_ref).entries.map(&:label)
      assert_equal true, access.project(@customer.reload).fetch("summary")
    end
  end

  def test_handler_cannot_fabricate_a_virtual_change_in_its_preview
    with_computed do
      handler = CollectionContractOperation.new
      handler.define_singleton_method(:preflight) { |_context, _record, _input| { points: 8, summary: "Fabricated summary" } }
      CollectionContractOperation.stub(:new, handler) do
        selected = captured
        proposal = RailsAiAdmin::Collections::Runner.new.preflight(context: context, resource: Resource, operation: :award,
          selection_ref: selected.selection_ref, input: { amount: 8, note: "Awarded" })
        refute proposal.is_a?(RailsAiAdmin::Collections::Result), proposal.inspect
        assert proposal.targets.all? { |target| !target.changes.key?("summary") }
        assert_equal 0, @customer.reload.points
      end
    end
  end

  def test_computation_version_and_dependency_changes_invalidate_intents_and_selections
    original = HasPoints.version
    %i[version dependencies].each do |change|
      with_computed do
        runner = RailsAiAdmin::Operations::Runner.new
        intent = runner.prepare(context: context, resource: Resource, operation: :update, target_id: @customer.id, expected_version: 0)
        selected = captured
        HasPoints.version "2" if change == :version
        dependencies = change == :dependencies ? [ :name ] : [ :points ]
        fields = Resource.fields.reject(&:virtual?)
        fields << RailsAiAdmin::Resource::FieldBuilder.new({}).virtual(:summary, type: :boolean, depends_on: dependencies, compute: "ComputedExecutionTest::HasPoints")
        Resource.stub(:fields, fields) do
          result = runner.execute(context: context, intent_ref: intent.id, input: { name: "Changed" }, human_confirmed: true)
          assert_equal "APPROVAL_INVALIDATED", result.code
          error = assert_raises(RailsAiAdmin::AccessDenied) do
            RailsAiAdmin::Selections::Builder.new.revalidate(context: context, selection_ref: selected.selection_ref)
          end
          assert_equal "SELECTION_INVALIDATED", error.code
          assert_equal "Alice", @customer.reload.name
        end
      end
      HasPoints.version original
    end
  ensure
    HasPoints.version original
  end

  def test_doctor_accepts_virtual_graph_without_sampling_domain_records
    with_computed do
      customer_queries = []
      listener = ->(*args) { customer_queries << args.last[:sql] if args.last[:sql].match?(/\bFROM\s+"?customers"?\b/i) }
      checks = nil
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        checks = RailsAiAdmin::Doctor.new.checks
      end
      assert_equal :ok, checks.find { |check| check.name == "schema:computed_batches" }.status
      assert_empty customer_queries
    end
  end
end
