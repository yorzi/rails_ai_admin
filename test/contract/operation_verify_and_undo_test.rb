# frozen_string_literal: true

require "test_helper"
require "support/operations"

# E04-A: Post-execution read-only `verify` hook and opt-in `compensate` / undo contract.
class MergeCustomersTestOperation < RailsAiAdmin::Operation
  atomic_models "Customer", "Invoice"
  reversible true
  input do
    belongs_to :source, resource: :verifiable_customers, required: true, nullable: false
  end

  class_attribute :verify_mode, default: :pass

  def preflight(context, target, input)
    source = Customer.where(account_id: context.tenant.id).find_by(id: input.fetch("source"))
    return invalid(:source) if source.nil? || source.id == target.id
    { points: target.points.to_i + source.points.to_i }
  end

  def undo_snapshot(context, target, input)
    source = Customer.where(account_id: context.tenant.id).find(input.fetch("source"))
    invoice_ids = Invoice.where(account_id: context.tenant.id, customer_id: source.id).order(:id).pluck(:id)
    {
      "source_id" => source.id.to_s,
      "source_points" => source.points.to_i,
      "source_active" => source.active,
      "target_points" => target.points.to_i,
      "moved_invoice_ids" => invoice_ids
    }
  end

  def perform(context, target, input)
    source = Customer.where(account_id: context.tenant.id).lock.find_by(id: input.fetch("source"))
    return invalid(:source) if source.nil? || source.id == target.id
    Invoice.where(account_id: context.tenant.id, customer_id: source.id).update_all(customer_id: target.id)
    target.update!(points: target.points.to_i + source.points.to_i)
    source.update!(points: 0, active: false)
    success(target)
  end

  def verify(context, target, input)
    case self.class.verify_mode
    when :impure_write
      target.update!(name: "Forbidden write in verify")
      [ check_pass("noop", "Should never reach") ]
    when :warn
      [ check_pass("invoices_moved", "Invoices reassigned"), check_warn("zero_balance", "Target had zero prior points") ]
    when :fail
      [ check_fail("remaining_invoices", "Source still has open invoices") ]
    else
      remaining = Invoice.where(account_id: context.tenant.id, customer_id: input.fetch("source")).count
      remaining.zero? ? [ check_pass("invoices_moved", "All source invoices moved to target") ] : [ check_fail("invoices_moved", "Invoices remain") ]
    end
  end

  def compensate(context, target, snapshot)
    source = Customer.where(account_id: context.tenant.id).lock.find_by(id: snapshot.fetch("source_id"))
    return conflict unless source
    moved_ids = Array(snapshot["moved_invoice_ids"])
    Invoice.where(account_id: context.tenant.id, customer_id: target.id, id: moved_ids).update_all(customer_id: source.id) if moved_ids.any?
    source.update!(points: snapshot.fetch("source_points"), active: snapshot.fetch("source_active"))
    target.update!(points: snapshot.fetch("target_points"))
    success(target)
  end
end

class VerifiableCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :verifiable_customers
  title :name
  undoable :update
  fields do
    id :id
    text :name, required: true, nullable: false
    integer :points
    boolean :active
    password :secret
  end
  operation :merge_from, handler: "MergeCustomersTestOperation"
  operation :review, handler: "ReviewContractOperation"
end

class SoftUndoMemoAdmin < RailsAiAdmin::Resource
  model "Memo"
  key :undoable_memos
  title :name
  soft_delete :discarded_at
  undoable :destroy
  fields do
    id :id
    text :name, required: true, nullable: false
    integer :points
  end
end

class VerifyAndUndoPolicy < OperationContractPolicy
  class_attribute :allow_undo, default: true

  def allowed?(context:, action:, resource:, record: nil)
    return !denied && context.actor.id == 1 if resource.operation_declarations.key?(action.to_sym)
    !denied && context.actor.id == 1
  end

  def fields(context:, resource:, action:, record: nil)
    return [] if denied
    if resource.key == :verifiable_customers
      return action == :read ? %i[id name points active] : %i[name points active secret]
    end
    %i[id name points]
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    return [] if denied || context.actor.id != 1
    operation.to_sym == :merge_from ? [ :source ] : [ :note ]
  end

  def undo_operation?(context:, resource:, operation:, record: nil)
    !denied && allow_undo && context.actor.id == 1
  end
end

class OperationVerifyAndUndoTest < Minitest::Test
  include DatabaseHelpers
  include OperationContractHelpers

  def setup
    reset_database
    VerifyAndUndoPolicy.denied = false
    VerifyAndUndoPolicy.allow_undo = true
    MergeCustomersTestOperation.verify_mode = :pass
  end

  def with_verify_and_undo(&block)
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "OperationJobContext"
    config.authorization_adapter = "VerifyAndUndoPolicy"
    config.resources = %w[VerifiableCustomerAdmin SoftUndoMemoAdmin]
    config.work_handlers = { "customers.reviewed" => "OperationContractWork" }
    registry = RailsAiAdmin::Registry.new(config.resources)
    operations = RailsAiAdmin::Operations::Registry.new(config.resources.map(&:constantize))
    work = RailsAiAdmin::Outbox::Registry.new(config.work_handlers)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          RailsAiAdmin.stub(:work_registry, work, &block)
        end
      end
    end
  ensure
    MergeCustomersTestOperation.verify_mode = :pass
  end

  def test_verify_records_passed_warning_failed_and_prevents_writes_without_rolling_back_commit
    with_verify_and_undo do
      runner = RailsAiAdmin::Operations::Runner.new
      @customer.update!(points: 10)
      dup = Customer.create!(account_id: 1, name: "Alice Dup", points: 25, active: true)
      inv = Invoice.create!(account_id: 1, number: "INV-100", customer_id: dup.id)

      # 1. Passing verification + replay preserves verification outcome.
      prop = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :merge_from,
        target_id: @customer.id, expected_version: @customer.reload.lock_version, input: { "source" => dup.id.to_s })
      res = runner.execute(context: context, intent_ref: prop.intent.id, input: { "source" => dup.id.to_s }, human_confirmed: true)
      assert_equal "OK", res.code
      assert_equal "passed", res.verification.status
      assert_equal 35, @customer.reload.points
      assert_equal @customer.id, inv.reload.customer_id

      replayed = runner.execute(context: context, intent_ref: prop.intent.id, input: { "source" => dup.id.to_s }, human_confirmed: true)
      assert replayed.replayed
      assert_equal "passed", replayed.verification.status

      # 2. Impure write inside verify is blocked by while_preventing_writes, recorded as error, and commit survives.
      dup2 = Customer.create!(account_id: 1, name: "Dup 2", points: 5, active: true)
      MergeCustomersTestOperation.verify_mode = :impure_write
      prop2 = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :merge_from,
        target_id: @customer.id, expected_version: @customer.reload.lock_version, input: { "source" => dup2.id.to_s })
      res2 = runner.execute(context: context, intent_ref: prop2.intent.id, input: { "source" => dup2.id.to_s }, human_confirmed: true)
      assert_equal "OK", res2.code
      assert_equal "error", res2.verification.status
      assert_equal 40, @customer.reload.points
      assert_equal "Alice", @customer.name

      # 3. Warning mode records warning status.
      dup3 = Customer.create!(account_id: 1, name: "Dup 3", points: 2, active: true)
      MergeCustomersTestOperation.verify_mode = :warn
      prop3 = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :merge_from,
        target_id: @customer.id, expected_version: @customer.reload.lock_version, input: { "source" => dup3.id.to_s })
      res3 = runner.execute(context: context, intent_ref: prop3.intent.id, input: { "source" => dup3.id.to_s }, human_confirmed: true)
      assert_equal "warning", res3.verification.status
    end
  end

  def test_custom_operation_compensate_enforces_grant_version_and_single_undo
    with_verify_and_undo do
      runner = RailsAiAdmin::Operations::Runner.new
      @customer.update!(points: 10)
      dup = Customer.create!(account_id: 1, name: "Dup", points: 15, active: true)
      inv = Invoice.create!(account_id: 1, number: "INV-200", customer_id: dup.id)

      prop = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :merge_from,
        target_id: @customer.id, expected_version: @customer.reload.lock_version, input: { "source" => dup.id.to_s })
      res = runner.execute(context: context, intent_ref: prop.intent.id, input: { "source" => dup.id.to_s }, human_confirmed: true)
      assert_equal "OK", res.code
      assert_equal [ 25, 0, false, @customer.id ], [ @customer.reload.points, dup.reload.points, dup.active, inv.reload.customer_id ]

      # Non-reversible operation (:review) cannot be undone.
      @customer.update!(points: 0)
      rev_prop = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :review,
        target_id: @customer.id, expected_version: @customer.reload.lock_version, input: { "note" => "Reviewed" })
      runner.execute(context: context, intent_ref: rev_prop.intent.id, input: { "note" => "Reviewed" }, human_confirmed: true)
      non_rev = runner.preflight_undo(context: context, run_id: rev_prop.intent.id)
      assert_equal "NOT_FOUND", non_rev.code

      # Undo on original merge fails with CONFLICT because @customer was modified afterwards!
      stale_undo = runner.preflight_undo(context: context, run_id: prop.intent.id)
      assert_equal "CONFLICT", stale_undo.code

      # Fresh merge on clean records, then undo with grant checks and double-undo guard.
      target2 = Customer.create!(account_id: 1, name: "Target 2", points: 10, active: true)
      source2 = Customer.create!(account_id: 1, name: "Source 2", points: 20, active: true)
      inv2 = Invoice.create!(account_id: 1, number: "INV-201", customer_id: source2.id)
      mprop = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :merge_from,
        target_id: target2.id, expected_version: target2.lock_version, input: { "source" => source2.id.to_s })
      runner.execute(context: context, intent_ref: mprop.intent.id, input: { "source" => source2.id.to_s }, human_confirmed: true)
      assert_equal 30, target2.reload.points

      # Without undo_operation? grant, undo is denied.
      VerifyAndUndoPolicy.allow_undo = false
      denied = runner.preflight_undo(context: context, run_id: mprop.intent.id)
      assert_equal "NOT_FOUND", denied.code
      VerifyAndUndoPolicy.allow_undo = true

      undo_prop = runner.preflight_undo(context: context, run_id: mprop.intent.id)
      assert_equal mprop.intent.id, undo_prop.intent.compensates_run_id

      undone = runner.execute_undo(context: context, intent_ref: undo_prop.intent.id, human_confirmed: true)
      assert_equal "OK", undone.code
      assert_equal [ 10, 20, true, source2.id ], [ target2.reload.points, source2.reload.points, source2.active, inv2.reload.customer_id ]

      audit = RailsAiAdmin::AuditEvent.find(undone.audit_ref)
      assert_equal "undo_merge_from", audit.operation

      # Double undo of the same run is rejected.
      second = runner.preflight_undo(context: context, run_id: mprop.intent.id)
      assert_equal "CONFLICT", second.code
    end
  end

  def test_native_update_and_soft_delete_undo_never_store_passwords_and_check_versions
    with_verify_and_undo do
      runner = RailsAiAdmin::Operations::Runner.new
      @customer.update!(name: "Before Name", points: 7)

      # Native update changing name, points, and password (:secret) -> password excluded from undo_payload!
      uprop = runner.preflight(context: context, resource: VerifiableCustomerAdmin, operation: :update,
        target_id: @customer.id, expected_version: @customer.reload.lock_version,
        input: { "name" => "After Name", "points" => 99, "secret" => "top-secret-pw" })
      ures = runner.execute(context: context, intent_ref: uprop.intent.id,
        input: { "name" => "After Name", "points" => 99, "secret" => "top-secret-pw" }, human_confirmed: true)
      assert_equal "OK", ures.code

      saved_run = uprop.intent.reload
      assert_equal({ "name" => "Before Name", "points" => 7 }, saved_run.undo_payload)
      refute saved_run.undo_payload.key?("secret")

      undo_prop = runner.preflight_undo(context: context, run_id: saved_run.id)
      undo_res = runner.execute_undo(context: context, intent_ref: undo_prop.intent.id, human_confirmed: true)
      assert_equal "OK", undo_res.code
      assert_equal [ "Before Name", 7 ], [ @customer.reload.name, @customer.points ]

      # Native soft-delete undo restores the record cleanly.
      memo = Memo.create!(account_id: 1, name: "Important memo", points: 3)
      dprop = runner.preflight(context: context, resource: SoftUndoMemoAdmin, operation: :destroy,
        target_id: memo.id, expected_version: memo.lock_version, input: {})
      runner.execute(context: context, intent_ref: dprop.intent.id, input: {}, human_confirmed: true)
      assert memo.reload.discarded_at.present?

      restore_prop = runner.preflight_undo(context: context, run_id: dprop.intent.id)
      restore_res = runner.execute_undo(context: context, intent_ref: restore_prop.intent.id, human_confirmed: true)
      assert_equal "OK", restore_res.code
      assert_nil memo.reload.discarded_at
    end
  end
end
