# frozen_string_literal: true

require "test_helper"
require "support/database"
require "minitest/mock"

class SelectionNote < ActiveRecord::Base
  self.table_name = "selection_contract_notes"
end
Customer.has_many :selection_notes, class_name: "SelectionNote", foreign_key: :customer_id

class SelectionPolicy < TestPolicy
  class_attribute :selection_grant, default: true
  class_attribute :join_duplicates, default: false
  class_attribute :eager_join, default: false
  def scope(context:, resource:, relation:)
    scoped = super
    return scoped.includes(:selection_notes).where(selection_contract_notes: { visible: true }) if eager_join
    join_duplicates ? scoped.joins("INNER JOIN customers selection_copies ON selection_copies.account_id = customers.account_id").order(name: :desc) : scoped
  end
  def select_records?(context:, resource:) = selection_grant && context.actor.id == 1
end

class SelectionsTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
    unless SelectionNote.table_exists?
      ActiveRecord::Schema.define do
        create_table :selection_contract_notes do |t|
          t.bigint :customer_id
          t.boolean :visible
          t.json :metadata
        end
      end
    end
    SelectionNote.delete_all
    SelectionPolicy.selection_grant = true
    SelectionPolicy.join_duplicates = false
    SelectionPolicy.eager_join = false
    @second = Customer.create!(account_id: 1, name: "Second")
  end

  def with_selection_policy
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "SelectionPolicy"
    RailsAiAdmin.stub(:configuration, config) { yield RailsAiAdmin::Selections::Builder.new }
  end

  def capture(builder, ids = [ @customer.id, @second.id ])
    builder.capture(context: context, resource: TestResource, target_ids: ids)
  end

  def test_fixed_canonical_manifest_and_current_labels_without_domain_changes
    with_selection_policy do |builder|
      result = capture(builder, [ @second.id.to_s, "0#{@customer.id}" ])
      assert_equal [ @customer.id.to_s, @second.id.to_s ].sort, result.targets.map(&:id)
      assert result.targets.frozen?
      assert_equal [ 0, 0 ], result.targets.map(&:expected_version)
      parent = RailsAiAdmin::Selection.find(result.selection_ref)
      assert_equal 2, parent.item_count
      assert_raises(ActiveRecord::ReadOnlyRecord) { parent.update!(manifest_digest: "changed") }
      assert_raises(ActiveRecord::ReadOnlyRecord) { RailsAiAdmin::SelectionItem.first.destroy! }
      assert_equal result.manifest_digest, builder.revalidate(context: context, selection_ref: result.selection_ref).manifest_digest
      assert_empty RailsAiAdmin::OperationRun.all
      assert_empty RailsAiAdmin::AuditEvent.all
      assert_equal "Alice", @customer.reload.name
      refute_includes parent.attributes.to_json, "Alice"
      refute_includes RailsAiAdmin::SelectionItem.first.attributes.to_json, "Alice"
    end
  end

  def test_selection_is_separate_default_deny_authority_and_all_targets_must_be_visible
    builder = RailsAiAdmin::Selections::Builder.new
    assert_raises(RailsAiAdmin::AccessDenied) { capture(builder) }
    with_selection_policy do |authorized|
      error = assert_raises(RailsAiAdmin::AccessDenied) { capture(authorized, [ @customer.id, @other.id ]) }
      assert_equal "NOT_FOUND", error.code
      assert_equal 0, RailsAiAdmin::Selection.count
      assert_raises(RailsAiAdmin::AccessDenied) { authorized.capture(context: context(actor: 2), resource: TestResource, target_ids: [ @customer.id ]) }
      TestPolicy.deny_show = true
      assert_raises(RailsAiAdmin::AccessDenied) { capture(authorized) }
      assert_empty RailsAiAdmin::Selection.all
    end
  end

  def test_bounds_bad_id_shapes_and_duplicate_canonical_targets_are_rejected_before_persistence
    with_selection_policy do |builder|
      [ [], [ @customer.id ] * 101, [ @customer.id, "0#{@customer.id}" ], [ "#{@customer.id}junk" ], [ nil ], [ true ], [ {} ], "all", [ "a" * 151 ], [ "1\n" ] ].each do |ids|
        error = assert_raises(RailsAiAdmin::AccessDenied) { capture(builder, ids) }
        assert_equal "INVALID_QUERY", error.code
      end
      assert_empty RailsAiAdmin::Selection.all
    end
  end

  def test_owner_tenant_epoch_expiry_and_current_policy_are_revalidated
    with_selection_policy do |builder|
      result = capture(builder)
      [ context(actor: 2), context(tenant: 2), context(version: "new") ].each do |fresh|
        assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: fresh, selection_ref: result.selection_ref) }
      end
      SelectionPolicy.selection_grant = false
      assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      SelectionPolicy.selection_grant = true
      RailsAiAdmin::Selection.where(id: result.selection_ref).update_all(expires_at: 1.second.ago)
      error = assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      assert_equal "SELECTION_EXPIRED", error.code
    end
  end

  def test_changed_deleted_or_replaced_targets_never_expand_from_a_new_query
    with_selection_policy do |builder|
      result = capture(builder)
      @customer.update!(name: "Changed")
      error = assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      assert_equal "CONFLICT", error.code
      result = capture(builder)
      @customer.update!(account_id: 2)
      assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      @second.destroy!
      Customer.create!(account_id: 1, name: "Replacement")
      assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
    end
  end

  def test_same_count_database_manifest_substitution_is_detected
    with_selection_policy do |builder|
      result = capture(builder, [ @customer.id ])
      RailsAiAdmin::SelectionItem.where(selection_id: result.selection_ref).update_all(target_id: @second.id.to_s)
      assert_raises(RailsAiAdmin::ConfigurationError) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_current_field_grants_avoid_stale_labels_and_digest_must_match
    with_selection_policy do |builder|
      result = capture(builder)
      TestPolicy.hide_name = true
      fresh = builder.revalidate(context: context, selection_ref: result.selection_ref)
      refute_includes fresh.targets.map(&:label), "Alice"
      assert fresh.targets.all? { |item| item.label.start_with?("Record #") }
      assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref, manifest_digest: "changed") }
    end
  end

  def test_uuid_identity_is_not_coerced_to_an_integer
    with_selection_policy do |builder|
      record = UuidCustomer.create!(account_id: 1, name: "UUID selection")
      result = builder.capture(context: context, resource: UuidCustomerAdmin, target_ids: [ record.id ])
      assert_equal record.id, result.targets.first.id
      assert_equal result, builder.revalidate(context: context, selection_ref: result.selection_ref)
    end
  end

  def test_resource_contract_changes_invalidate_the_snapshot
    with_selection_policy do |builder|
      result = capture(builder)
      TestResource.stub(:policy, "ChangedPolicy") do
        error = assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
        assert_equal "SELECTION_INVALIDATED", error.code
      end
      assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref, resource: UuidCustomerAdmin) }
    end
  end

  def test_hundred_target_limit_uses_a_bounded_query_and_labels
    with_selection_policy do |builder|
      @customer.update!(name: "L" * 300)
      98.times { |number| Customer.create!(account_id: 1, name: "Target #{number}") }
      ids = Customer.where(account_id: 1).pluck(:id)
      assert_equal 100, ids.size
      selects = []
      listener = ->(*args) { selects << args.last[:sql] if args.last[:sql].match?(/SELECT.*FROM ["`]?customers["`]?/i) }
      result = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { capture(builder, ids) }
      assert_equal 100, result.targets.size
      assert_equal 1, selects.size
      assert result.targets.all? { |item| item.label.length <= 120 }
      assert_equal 100, RailsAiAdmin::SelectionItem.count
    end
  end

  def test_lookup_callbacks_cannot_write_during_capture_or_revalidation
    with_selection_policy do |builder|
      result = capture(builder)
      callback = ->(record) { record.update!(points: record.points + 1) }
      Customer.set_callback(:find, :after, callback)
      begin
        assert_raises(RailsAiAdmin::ConfigurationError) { capture(builder) }
        assert_raises(RailsAiAdmin::ConfigurationError) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      ensure
        Customer.skip_callback(:find, :after, callback)
      end
      assert_equal 0, @customer.reload.points
      assert_equal 1, RailsAiAdmin::Selection.count
    end
  end

  def test_storage_cannot_move_to_another_connection_pool
    with_selection_policy do |builder|
      different_pool = Object.new
      RailsAiAdmin::Selection.stub(:connection_pool, different_pool) do
        assert_raises(RailsAiAdmin::ConfigurationError) { capture(builder) }
      end
    end
  end

  def test_failed_item_insert_rolls_back_the_whole_snapshot
    with_selection_policy do |builder|
      RailsAiAdmin::SelectionItem.stub(:insert_all!, ->(*) { raise ActiveRecord::StatementInvalid, "synthetic failure" }) do
        assert_raises(ActiveRecord::StatementInvalid) { capture(builder) }
      end
      assert_empty RailsAiAdmin::Selection.all
      assert_empty RailsAiAdmin::SelectionItem.all
    end
  end
  def test_primary_key_semantics_cannot_change_under_a_fixed_target_id
    with_selection_policy do |builder|
      result = capture(builder, [ @customer.id ])
      Customer.create!(account_id: 1, name: "Different real customer", points: @customer.id)
      original_key = Customer.primary_key
      Customer.primary_key = "points"
      error = assert_raises(RailsAiAdmin::AccessDenied) { builder.revalidate(context: context, selection_ref: result.selection_ref) }
      assert_equal "SELECTION_INVALIDATED", error.code
    ensure
      Customer.primary_key = original_key if original_key
    end
  end
  def test_join_multiplicity_is_deduplicated_inside_the_authorized_query_before_bounding
    with_selection_policy do |builder|
      98.times { |number| Customer.create!(account_id: 1, name: "Joined target #{number}") }
      ids = Customer.where(account_id: 1).pluck(:id)
      SelectionPolicy.join_duplicates = true
      result = capture(builder, ids)
      assert_equal ids.map(&:to_s).sort, result.targets.map(&:id)
      assert_equal result, builder.revalidate(context: context, selection_ref: result.selection_ref)
      assert_raises(RailsAiAdmin::AccessDenied) { capture(builder, [ @customer.id, @other.id ]) }
    end
  end
  def test_includes_scope_predicates_keep_their_public_relation_join_semantics
    with_selection_policy do |builder|
      SelectionNote.create!(customer_id: @customer.id, visible: true, metadata: { "synthetic" => true })
      SelectionNote.create!(customer_id: @customer.id, visible: true)
      SelectionNote.create!(customer_id: @second.id, visible: false)
      SelectionNote.create!(customer_id: @other.id, visible: true)
      SelectionPolicy.eager_join = true
      result = capture(builder, [ @customer.id ])
      assert_equal [ @customer.id.to_s ], result.targets.map(&:id)
      assert_equal result, builder.revalidate(context: context, selection_ref: result.selection_ref)
      assert_raises(RailsAiAdmin::AccessDenied) { capture(builder, [ @second.id ]) }
      assert_raises(RailsAiAdmin::AccessDenied) { capture(builder, [ @other.id ]) }
    end
  end
end
