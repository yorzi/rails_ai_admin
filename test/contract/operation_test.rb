# frozen_string_literal: true

require "test_helper"
require "support/database"
require "minitest/mock"

class OperationTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
    @runner = RailsAiAdmin::Operations::Runner.new
  end

  def prepare(operation: :update, input: nil, context: self.context, target_id: @customer.id, version: @customer.lock_version)
    @runner.prepare(context: context, resource: TestResource, operation: operation, target_id: target_id, expected_version: version, input: input)
  end

  def execute(intent, input = { "name" => "Changed" }, context: self.context, human: true, origin: :ui)
    @runner.execute(context: context, intent_ref: intent.id, input: input, human_confirmed: human, origin: origin)
  end

  def test_database_unique_rejection_returns_a_conflict_and_rolls_back_the_second_create
    index_name = "raa_contract_unique_customer_name"
    Customer.connection.add_index(:customers, [ :account_id, :name ], unique: true, name: index_name)
    first = @runner.prepare(context: context, resource: TestResource, operation: :create)
    second = @runner.prepare(context: context, resource: TestResource, operation: :create)
    assert @runner.execute(context: context, intent_ref: first.id, input: { name: "Unique database value" }, human_confirmed: true).success?
    result = @runner.execute(context: context, intent_ref: second.id, input: { name: "Unique database value" }, human_confirmed: true)
    assert_equal "CONFLICT", result.code
    assert_equal 1, Customer.where(account_id: 1, name: "Unique database value").count
    assert_equal "proposed", second.reload.status
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    assert_nil second.input_digest
  ensure
    Customer.connection.remove_index(:customers, name: index_name) if Customer.connection.index_exists?(:customers, [ :account_id, :name ], name: index_name)
  end

  def test_success_commits_domain_receipt_confirmation_and_audit_together
    intent = prepare
    result = execute(intent)
    assert result.success?, result.code
    assert_equal "Changed", @customer.reload.name
    assert_equal 1, @customer.lock_version
    assert_equal "succeeded", intent.reload.status
    assert_equal context.actor_ref, intent.approved_by_ref
    assert_equal intent.input_digest, intent.approved_digest
    audit = RailsAiAdmin::AuditEvent.find(result.audit_ref)
    assert_equal "succeeded", audit.status
    assert_equal [ "name" ], audit.changed_fields
    refute_includes audit.attributes.to_json, "never show"
    refute_includes intent.attributes.to_json, "Changed"
  end

  def test_replay_returns_current_projection_without_repeating_write
    intent = prepare
    first = execute(intent)
    @customer.reload.update!(name: "Newer value")
    TestPolicy.hide_name = true
    result = execute(intent, { "name" => "Changed" }, origin: :surface)
    assert result.success?
    assert result.replayed
    assert_equal first.audit_ref, result.audit_ref
    assert_equal 2, @customer.reload.lock_version
    refute result.values.key?("name")
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  end

  def test_same_intent_different_payload_conflicts
    intent = prepare
    assert execute(intent).success?
    assert_equal "IDEMPOTENCY_CONFLICT", execute(intent, { "name" => "Different" }).code
    assert_equal "Changed", @customer.reload.name
  end

  def test_prebound_proposal_cannot_be_edited_or_self_approved
    intent = prepare(input: { "name" => "Proposal" })
    assert_equal "APPROVAL_REQUIRED", execute(intent, { "name" => "Proposal" }, human: false, origin: :assistant).code
    assert_equal "APPROVAL_INVALIDATED", execute(intent, { "name" => "Altered" }).code
    assert execute(intent, { "name" => "Proposal" }).success?
  end

  def test_conflicting_version_preserves_the_other_edit
    intent = prepare
    @customer.update!(name: "Concurrent editor")
    assert_equal "CONFLICT", execute(intent).code
    assert_equal "Concurrent editor", @customer.reload.name
    assert_equal "proposed", intent.reload.status
  end

  def test_reauthorization_and_identity_binding_apply_to_successful_receipts
    intent = prepare
    assert execute(intent).success?
    assert_equal "NOT_FOUND", execute(intent, context: context(actor: 2)).code
    assert_equal "NOT_FOUND", execute(intent, context: context(tenant: 2)).code
    assert_equal "APPROVAL_INVALIDATED", execute(intent, context: context(version: "2")).code
    TestPolicy.denied = true
    assert_equal "NOT_FOUND", execute(intent).code
  end

  def test_unknown_intents_are_never_recreated
    result = @runner.execute(context: context, intent_ref: "not-a-server-intent", input: {}, human_confirmed: true)
    assert_equal "NOT_FOUND", result.code
    assert_equal 0, RailsAiAdmin::OperationRun.count
  end

  def test_expiry_and_omitted_human_confirmation_do_not_write
    intent = prepare
    assert_equal "APPROVAL_REQUIRED", execute(intent, human: false).code
    intent.update!(expires_at: 1.minute.ago)
    assert_equal "APPROVAL_EXPIRED", execute(intent).code
    assert_equal "Alice", @customer.reload.name
  end

  def test_validation_failure_keeps_form_intent_reusable_without_consuming_approval
    intent = prepare
    result = execute(intent, { "name" => "" })
    assert_equal "VALIDATION_FAILED", result.code
    assert_equal [ "is invalid" ], result.errors["name"]
    assert_equal "proposed", intent.reload.status
    assert_nil intent.approved_by_ref
    assert execute(intent).success?
  end

  def test_hidden_readonly_unknown_and_nested_inputs_never_mass_assign
    intent = prepare
    [ { "secret" => "attack" }, { "id" => "3" }, { "account_id" => 2 }, { "name" => { "sql" => "attack" } } ].each do |input|
      refute execute(intent, input).success?
    end
    assert_equal "Alice", @customer.reload.name
    assert_equal 1, @customer.account_id
    assert_equal "never show", @customer.secret
  end

  def test_cross_tenant_target_is_not_found_even_with_a_valid_actor
    assert_raises(RailsAiAdmin::AccessDenied) { prepare(target_id: @other.id) }
  end

  def test_audit_failure_rolls_back_domain_and_consumed_confirmation
    intent = prepare
    RailsAiAdmin::AuditEvent.stub(:create!, ->(**) { raise "forced audit failure" }) do
      assert_raises(RuntimeError) { execute(intent) }
    end
    assert_equal "Alice", @customer.reload.name
    assert_equal "proposed", intent.reload.status
    assert_nil intent.approved_by_ref
  end

  def test_outer_transaction_rollback_also_rolls_back_receipt_and_audit
    intent = prepare
    ActiveRecord::Base.transaction do
      assert execute(intent).success?
      raise ActiveRecord::Rollback
    end
    assert_equal "Alice", @customer.reload.name
    assert_equal "proposed", intent.reload.status
    assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
  end

  def test_create_uses_scoped_relation_and_has_no_target_before_execution
    intent = prepare(operation: :create, target_id: nil, version: nil)
    result = execute(intent, { "name" => "Created", "active" => false, "points" => 0 })
    assert result.success?, result.code
    created = Customer.find(result.record_id)
    assert_equal 1, created.account_id
    refute created.active
    assert_equal 0, created.points
    assert execute(intent, { "name" => "Created", "active" => false, "points" => "0" }).replayed
    assert_equal 1, Customer.where(name: "Created").count
  end

  def test_delete_requires_an_explicit_confirmation_and_replay_has_no_snapshot
    intent = prepare(operation: :destroy)
    assert_equal "APPROVAL_REQUIRED", execute(intent, {}, human: false).code
    assert execute(intent, {}).success?
    refute Customer.exists?(@customer.id)
    result = execute(intent, {})
    assert result.success?
    assert_empty result.values
  end

  def test_callback_rollback_never_creates_a_successful_receipt
    [ :before_save, :after_save ].each do |callback|
      hook = -> { raise ActiveRecord::Rollback if name == "rollback" }
      Customer.set_callback(:save, callback == :before_save ? :before : :after, hook)
      intent = prepare
      result = execute(intent, { "name" => "rollback" })
      assert_equal "VALIDATION_FAILED", result.code
      assert_equal "Alice", @customer.reload.name
      assert_equal "proposed", intent.reload.status
      assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
    ensure
      Customer.skip_callback(:save, callback == :before_save ? :before : :after, hook)
    end
  end
  def test_create_is_authorized_on_the_proposed_record
    TestPolicy.limit_create = true
    intent = prepare(operation: :create, target_id: nil, version: nil)
    result = execute(intent, { "name" => "Over limit", "points" => "99" })
    assert_equal "NOT_FOUND", result.code
    refute Customer.exists?(name: "Over limit")
    assert_equal "proposed", intent.reload.status
  end

  def test_blind_write_never_projects_unreadable_records
    TestPolicy.deny_show = true
    intent = prepare
    first = execute(intent)
    assert first.success?
    assert_empty first.values
    replay = execute(intent)
    assert replay.replayed
    assert_empty replay.values
  end

  def test_after_commit_errors_preserve_the_committed_outcome
    [ ActiveRecord::RecordInvalid.new(@customer), ActiveRecord::LockWaitTimeout.new("synthetic callback failure"), RuntimeError.new("callback failed") ].each_with_index do |exception, index|
      input = { "name" => "Committed #{index}" }
      hook = -> { raise exception if name == input["name"] }
      Customer.set_callback(:commit, :after, hook)
      @customer.reload
      intent = prepare
      result = execute(intent, input)
      assert result.success?, result.code
      assert_equal "POST_COMMIT_CALLBACK_FAILED", result.warning
      assert_equal input["name"], @customer.reload.name
      assert_equal "succeeded", intent.reload.status
      assert_empty RailsAiAdmin::AuditEvent.where(correlation_ref: intent.id, status: "rejected")
      replay = execute(intent, input)
      assert replay.replayed
      assert_equal "POST_COMMIT_CALLBACK_FAILED", replay.warning
    ensure
      Customer.skip_callback(:commit, :after, hook)
    end
  end

  def test_callback_abort_is_a_validation_failure
    hook = -> { throw :abort if name == "abort" }
    Customer.set_callback(:save, :before, hook)
    intent = prepare
    assert_equal "VALIDATION_FAILED", execute(intent, { "name" => "abort" }).code
    assert_equal "Alice", @customer.reload.name
    assert_equal "proposed", intent.reload.status
  ensure
    Customer.skip_callback(:save, :before, hook)
  end

  def test_duplicate_concurrent_submissions_have_one_committed_effect
    intent = prepare
    ready, start = Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          execute(intent)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    assert results.any?(&:success?), results.map(&:code).inspect
    assert results.all? { |result| result.success? || result.code == "CONFLICT" }
    assert execute(intent).replayed
    assert_equal 1, @customer.reload.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  end

  def test_audit_records_are_readonly_through_model_api
    result = execute(prepare)
    audit = RailsAiAdmin::AuditEvent.find(result.audit_ref)
    assert_raises(ActiveRecord::ReadOnlyRecord) { audit.update!(code: "forged") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { audit.destroy! }
  end
  def test_before_commit_rollback_returns_a_controlled_failure
    hook = -> { raise ActiveRecord::Rollback if name == "rollback_before_commit" }
    Customer.set_callback(:before_commit, :before, hook)
    intent = prepare
    result = execute(intent, { "name" => "rollback_before_commit" })
    assert_equal "VALIDATION_FAILED", result.code
    assert_equal "Alice", @customer.reload.name
    assert_equal "proposed", intent.reload.status
    assert_empty RailsAiAdmin::AuditEvent.where(status: "succeeded")
  ensure
    Customer.skip_callback(:before_commit, :before, hook)
  end

  def test_create_replay_reauthorizes_new_record_policy_and_returns_no_blind_data
    TestPolicy.new_only_create = true
    TestPolicy.deny_show = true
    intent = prepare(operation: :create, target_id: nil, version: nil)
    first = execute(intent, { "name" => "Blind create" })
    assert first.success?
    assert_empty first.values
    replay = execute(intent, { "name" => "Blind create" })
    assert replay.success?, replay.code
    assert replay.replayed
    assert_empty replay.values
    assert_equal 1, Customer.where(name: "Blind create").count
  end

  def test_limited_policy_scope_cannot_be_widened_for_member_or_write
    TestPolicy.limited_scope = true
    access = RailsAiAdmin::Authorization::Access.new(context, TestResource)
    assert_raises(RailsAiAdmin::ConfigurationError) { access.find!(@customer.id) }
    assert_raises(RailsAiAdmin::ConfigurationError) { prepare }
    assert_equal "Alice", @customer.reload.name
  end
  def test_independent_intents_for_one_version_do_not_both_commit
    intents = [ prepare, prepare ]
    ready, start = Queue.new, Queue.new
    threads = intents.map do |intent|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          execute(intent)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    assert_equal 1, results.count(&:success?), results.map(&:code).inspect
    assert_equal 1, results.count { |result| result.code == "CONFLICT" }
    assert_equal 1, @customer.reload.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    loser = intents.zip(results).find { |_, result| !result.success? }.first
    assert_equal "CONFLICT", execute(loser).code
    assert_equal "proposed", loser.reload.status
  end
end
