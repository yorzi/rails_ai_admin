require_relative "../config/environment"
require "json"

mode = ARGV.fetch(0)
metadata_file = Rails.root.join("tmp/recovery.json")
ready_file = Rails.root.join("tmp/recovery.ready")
FileUtils.mkdir_p(metadata_file.dirname)
if mode == "prepare"
  actor = StaffUser.create!(email: "recovery-#{SecureRandom.hex(6)}@example.test", password: "synthetic-fixture-password", role: "admin")
  tenant = Tenant.create!(name: "Recovery tenant")
  actor.tenant_memberships.create!(tenant: tenant)
  record = SupportTicket.create!(tenant: tenant, subject: "Before recovery")
  context = RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version)
  intent = RailsAiAdmin::Operations::Runner.new.prepare(context: context, resource: TicketAdmin,
    operation: :update, target_id: record.id, expected_version: record.lock_version)
  metadata_file.write(JSON.generate(actor_id: actor.id, tenant_id: tenant.id, record_id: record.id, intent_ref: intent.id))
  FileUtils.rm_f(ready_file)
  exit
end

metadata = JSON.parse(metadata_file.read)
actor = StaffUser.find(metadata.fetch("actor_id"))
tenant = actor.tenants.find(metadata.fetch("tenant_id"))
context = RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version)
runner = RailsAiAdmin::Operations::Runner.new
input = { "subject" => "Recovered intent" }
if mode == "pause_before_commit"
  SupportTicket.after_update do
    ready_file.write("domain SQL completed inside the open transaction")
    STDIN.read # Parent kills this confirmed live child before audit/commit.
  end
end
if mode == "verify_rollback"
  record = SupportTicket.find(metadata.fetch("record_id"))
  raise "Domain mutation survived crash" unless record.subject == "Before recovery" && record.lock_version == 0
  raise "Intent claim survived crash" unless RailsAiAdmin::OperationRun.find(metadata.fetch("intent_ref")).status == "proposed"
  raise "Success audit survived crash" if RailsAiAdmin::AuditEvent.where(correlation_ref: metadata.fetch("intent_ref"), status: "succeeded").exists?
  puts "Killed transaction rolled back domain, claim and audit"
  exit
end
result = runner.execute(context: context, intent_ref: metadata.fetch("intent_ref"), input: input, human_confirmed: true)
raise "Operation did not succeed: #{result.code}" unless result.success?
if mode == "commit_and_exit"
  # Simulate death after durable commit but before returning a response. Do not
  # update the metadata with a receipt; retry knows only the original intent.
  exit! 0
end
raise "Expected replay" unless result.replayed
record = SupportTicket.find(metadata.fetch("record_id"))
raise "Business mutation was repeated" unless record.lock_version == 1 && record.subject == "Recovered intent"
raise "Audit was repeated" unless RailsAiAdmin::AuditEvent.where(correlation_ref: metadata.fetch("intent_ref"), status: "succeeded").count == 1
puts "Fresh-process replay returned the original receipt with one committed write"
