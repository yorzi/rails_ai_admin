require_relative "../config/environment"
require "json"
require "fileutils"

mode = ARGV.fetch(0)
metadata_path = Rails.root.join("tmp/outbox-recovery.json")
directory = Rails.root.join("tmp/synthetic_deliveries")
if mode == "prepare"
  FileUtils.rm_rf(directory)
  actor = StaffUser.create!(email: "outbox-#{SecureRandom.hex(6)}@example.test", password: "synthetic-fixture-password", role: "admin")
  tenant = Tenant.create!(name: "Outbox recovery tenant")
  actor.tenant_memberships.create!(tenant: tenant)
  ticket = SupportTicket.create!(tenant: tenant, subject: "Outbox recovery ticket")
  context = RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version.to_s)
  runner = RailsAiAdmin::Operations::Runner.new
  proposal = runner.preflight(context: context, resource: TicketAdmin, operation: :triage,
    target_id: ticket.id, expected_version: ticket.lock_version, input: { decision: ARGV.fetch(1), review_note: "synthetic recovery note" })
  result = runner.execute(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
  raise "Business operation failed" unless result.success? && result.work_refs.size == 1
  metadata = { ticket_id: ticket.id, run_ref: proposal.intent.id, work_ref: result.work_refs.first, tenant_id: tenant.id }
  File.open(metadata_path, "w") { |file| file.write(JSON.generate(metadata)); file.flush; file.fsync }
  # Abrupt business-process death after commit, before any delivery notification.
  exit! 0
end

metadata = JSON.parse(metadata_path.read)
item = RailsAiAdmin::WorkItem.find(metadata.fetch("work_ref"))
if mode == "deliver"
  result = RailsAiAdmin::Outbox::Dispatcher.new.run(item.id)
  puts "Fresh worker outcome: #{result.status}/#{result.code}"
elsif mode == "verify_crash"
  raise "Worker was not durably claimed" unless item.status == "running" && item.generation == 1 && item.attempts == 1
  started = ARGV.fetch(1) == "after"
  raise "Wrong crash boundary" unless item.effect_started_at.present? == started
  raise "Business receipt lost after process death" unless RailsAiAdmin::OperationRun.find(metadata.fetch("run_ref")).status == "succeeded"
  puts "Dead worker confirmed at #{ARGV.fetch(1)}-effect boundary; durable business receipt retained"
elsif mode == "wait_for_lease"
  duration = [ item.lease_expires_at - Time.current + 0.05, 0 ].max
  raise "Unexpected fixture lease duration" if duration > 6
  sleep duration
  raise "Lease is not expired" if item.reload.lease_expires_at > Time.current
elsif mode == "verify_result"
  expected, requests = ARGV.fetch(1), Integer(ARGV.fetch(2))
  raise "Unexpected work status #{item.status}" unless item.status == expected
  ticket = SupportTicket.find(metadata.fetch("ticket_id"))
  raise "Business mutation repeated" unless ticket.lock_version == 1
  raise "Success audit repeated" unless RailsAiAdmin::AuditEvent.where(correlation_ref: metadata.fetch("run_ref"), status: "succeeded").count == 1
  raise "Downstream applied more than once" unless directory.join("applications.log").readlines.size == 1
  raise "Unexpected downstream request count" unless directory.join("requests.log").readlines.size == requests
  expected_attempts = expected == "succeeded" ? 2 : 1
  raise "Wrong attempt/generation fencing" unless item.attempts == expected_attempts && item.generation == expected_attempts
  receipt = JSON.parse(directory.join("#{item.id}.json").read)
  raise "Wrong tenant delivered" unless receipt.fetch("tenant_ref") == "raa:tenant:Tenant:#{metadata.fetch('tenant_id')}"
  raise "Sensitive note leaked to the downstream" if receipt.to_json.include?("synthetic recovery note")
  puts "#{expected}: business once, downstream once, #{requests} request(s), durable fencing verified"
else
  raise "Unknown probe mode"
end
