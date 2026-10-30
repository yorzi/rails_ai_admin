# frozen_string_literal: true

require "test_helper"
require "support/application"

class FormRecoveryTest < Minitest::Test
  include DatabaseHelpers

  def setup
    reset_database
    @runner = RailsAiAdmin::Operations::Runner.new
  end

  def prepare(operation: :update, **options)
    @runner.prepare(context: context, resource: TestResource, operation: operation,
      **(operation == :create ? {} : { target_id: @customer.id, expected_version: 0 }), **options)
  end

  def resume(intent, ctx: context, resource: TestResource)
    @runner.resume_form(context: ctx, resource: resource, intent_ref: intent.id)
  end

  def test_expired_session_recovers_the_same_unconsumed_intent_with_fresh_epoch_without_writes
    intent = prepare
    intent.update!(expires_at: 1.minute.ago)
    before = RailsAiAdmin::OperationRun.count
    result = resume(intent, ctx: context(version: "2"))
    assert_equal intent.id, result.intent.id
    assert_equal @customer.id, result.record.id
    assert_equal "2", intent.reload.security_version
    assert_operator intent.expires_at, :>, Time.current
    assert_equal "proposed", intent.status
    assert_nil intent.input_digest
    assert_nil intent.confirmed_at
    assert_equal before, RailsAiAdmin::OperationRun.count
    assert_equal "Alice", @customer.reload.name
    assert_empty RailsAiAdmin::AuditEvent.all
    outcome = @runner.execute(context: context(version: "2"), intent_ref: intent.id, input: { name: "Explicit save" }, human_confirmed: true)
    assert outcome.success?
    assert_equal "Explicit save", @customer.reload.name
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent, ctx: context(version: "2")) }
  end

  def test_create_recovery_never_reissues_an_intent_after_a_possible_commit
    intent = prepare(operation: :create)
    2.times { assert_equal intent.id, resume(intent).intent.id }
    count = Customer.count
    assert @runner.execute(context: context, intent_ref: intent.id, input: { name: "Created once" }, human_confirmed: true).success?
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent) }
    assert_equal count + 1, Customer.count
    assert_equal 1, RailsAiAdmin::OperationRun.where(id: intent.id).count
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  end

  def test_identity_tenant_resource_scope_action_and_record_version_are_rechecked
    intent = prepare
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent, ctx: context(actor: 2)) }
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent, ctx: context(tenant: 2)) }
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent, resource: UuidCustomerAdmin) }
    TestPolicy.denied = true
    assert_raises(RailsAiAdmin::AccessDenied) { resume(intent) }
    TestPolicy.denied = false
    @customer.update!(points: 4)
    error = assert_raises(RailsAiAdmin::AccessDenied) { resume(intent) }
    assert_equal "CONFLICT", error.code
    assert_equal "1", intent.reload.security_version
  end

  def test_input_bound_non_ui_and_preapproved_intents_are_not_weakened
    changes = [ { input_digest: "fixed" }, { origin: "assistant" }, { approved_by_ref: context.actor_ref }, { confirmed_at: Time.current }, { approved_digest: "fixed" }, { status: "running" }, { operation_version: "changed schema" } ]
    changes.each do |attributes|
      intent = prepare
      intent.update!(attributes)
      before = intent.attributes
      assert_raises(RailsAiAdmin::AccessDenied) { resume(intent) }
      assert_equal before, intent.reload.attributes
    end
  end

  def test_delete_and_child_intents_are_ineligible_for_form_recovery
    destroy = prepare(operation: :destroy)
    assert_raises(RailsAiAdmin::AccessDenied) { resume(destroy) }
    parent = prepare
    child = prepare
    child.update!(parent_run_id: parent.id)
    assert_raises(RailsAiAdmin::AccessDenied) { resume(child) }
    assert_equal "proposed", child.reload.status
    assert_equal "proposed", parent.reload.status
    assert_empty RailsAiAdmin::AuditEvent.all
  end

  def test_recovery_has_an_absolute_age_bound_and_expiry_cannot_extend_past_it
    intent = prepare
    intent.update!(created_at: 59.minutes.ago)
    assert_operator resume(intent).intent.expires_at, :<=, intent.created_at + 1.hour
    intent.update!(created_at: 61.minutes.ago)
    error = assert_raises(RailsAiAdmin::AccessDenied) { resume(intent) }
    assert_equal "APPROVAL_EXPIRED", error.code
    assert_equal "proposed", intent.reload.status
  end

  def test_authentication_link_configuration_accepts_only_fixed_internal_paths
    [ "https://example.test", "//example.test", "/login?next=//evil.test", "/login#frag", "/../login", "/%2flogin", "/login\n" ].each do |path|
      config = RailsAiAdmin::Configuration.new
      config.authentication_path = path
      assert_raises(RailsAiAdmin::ConfigurationError) { config.finalize! }
    end
    config = RailsAiAdmin::Configuration.new
    config.authentication_path = "/staff_users/sign_in"
    config.finalize!
    assert config.authentication_path.frozen?
  end
end
