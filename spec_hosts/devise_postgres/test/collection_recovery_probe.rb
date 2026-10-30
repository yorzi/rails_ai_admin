require_relative "../config/environment"
require "json"
require "fileutils"

mode = ARGV.fetch(0)
metadata_path = Rails.root.join("tmp/collection-recovery.json")
ready_path = Rails.root.join("tmp/collection-recovery.ready")
FileUtils.mkdir_p(metadata_path.dirname)
if mode == "prepare"
  actor = StaffUser.create!(email: "collection-#{SecureRandom.hex(6)}@example.test", password: "synthetic-fixture-password", role: "admin")
  tenant = Tenant.create!(name: "Collection recovery tenant")
  actor.tenant_memberships.create!(tenant: tenant)
  tickets = 2.times.map { |index| SupportTicket.create!(tenant: tenant, subject: "Recovery item #{index}") }
  context = RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version.to_s)
  selection = RailsAiAdmin::Selections::Builder.new.capture(context: context, resource: TicketAdmin, target_ids: tickets.map(&:id))
  proposal = RailsAiAdmin::Collections::Runner.new.preflight(context: context, resource: TicketAdmin,
    operation: :bulk_triage, selection_ref: selection.selection_ref, input: { "decision" => "triage", "review_note" => "synthetic recovery note" })
  result = RailsAiAdmin::Collections::Runner.new.admit(context: context, intent_ref: proposal.intent.id, input: proposal.values, human_confirmed: true)
  raise "Admission failed" unless result.accepted? && result.status == "queued"
  metadata = { job_ref: result.job_ref, ticket_ids: tickets.map(&:id) }
  File.open(metadata_path, "w") { |file| file.write(JSON.generate(metadata)); file.flush; file.fsync }
  FileUtils.rm_f(ready_path)
  puts "One approval durably admitted two exact targets without a business write"
  exit
end

metadata = JSON.parse(metadata_path.read)
parent = RailsAiAdmin::OperationRun.find(metadata.fetch("job_ref"))
items = RailsAiAdmin::BatchItem.where(parent_run_id: parent.id)
tickets = SupportTicket.where(id: metadata.fetch("ticket_ids"))
case mode
when "claim_and_exit"
  claim = RailsAiAdmin::Collections::Dispatcher.new.claim_next(parent.id)
  raise "No durable claim" unless claim
  exit! 0
when "pause_before_commit"
  SupportTicket.after_update do
    ready_path.write("live item transaction reached domain SQL")
    STDIN.read
  end
  RailsAiAdmin::Collections::Dispatcher.new.run(parent.id)
when "commit_then_exit"
  SupportTicket.after_commit { exit! 0 if previous_changes.key?("state") }
  RailsAiAdmin::Collections::Dispatcher.new.run(parent.id, limit: 1)
when "verify_uncommitted"
  raise "Business survived uncommitted death" unless tickets.pluck(:state).uniq == [ "open" ] && tickets.pluck(:lock_version).uniq == [ 0 ]
  raise "Durable lease lost" unless items.where(status: "running", generation: 1, attempts: 1).count == 1
  raise "Child approval or uncommitted receipt survived" unless RailsAiAdmin::OperationRun.where(parent_run_id: parent.id).pluck(:status).uniq == [ "proposed" ]
  raise "Audit survived rollback" if RailsAiAdmin::AuditEvent.where(correlation_ref: items.select(:operation_run_id), status: "succeeded").exists?
  puts "Dead worker left only its durable lease; domain/audit/child receipt rolled back"
when "wait_for_lease"
  item = items.find_by!(status: "running")
  duration = [ item.lease_expires_at - Time.current + 0.05, 0 ].max
  raise "Unexpected lease budget" if duration > 6
  sleep duration
  raise "Lease is not expired" unless item.reload.lease_expires_at <= Time.current
when "verify_committed"
  raise "Committed item receipt lost" unless items.where(status: "succeeded").count == 1 && items.where(status: "queued").count == 1
  raise "Committed domain lost" unless tickets.where(state: "triaged", lock_version: 1).count == 1
  puts "Process died after atomic business/item/audit commit; remaining target stays queued"
when "deliver"
  result = RailsAiAdmin::Collections::Dispatcher.new.run(parent.id)
  raise "Recovery did not finish" unless result.status == "succeeded"
when "verify_completed"
  raise "Parent success receipt missing" unless parent.status == "succeeded" && parent.approved_by_ref && parent.confirmed_at
  raise "A target ran twice or remained uncommitted" unless tickets.count == 2 && tickets.pluck(:state).uniq == [ "triaged" ] && tickets.pluck(:lock_version).uniq == [ 1 ]
  raise "Wrong item receipts" unless items.where(status: "succeeded").count == 2
  raise "Wrong success audit count" unless RailsAiAdmin::AuditEvent.where(correlation_ref: items.select(:operation_run_id), status: "succeeded").count == 2
  children = RailsAiAdmin::OperationRun.where(parent_run_id: parent.id)
  raise "Worker fabricated a second approval" unless children.where.not(confirmed_at: nil).empty? && children.where.not(approved_by_ref: nil).empty?
  raise "Outbox lost or duplicated" unless RailsAiAdmin::WorkItem.where(operation_run_id: children.select(:id)).count == 2
  expected_attempts = ARGV.fetch(1) == "reclaimed" ? [ 1, 2 ] : [ 1, 1 ]
  raise "Unexpected retry generation" unless items.pluck(:attempts).sort == expected_attempts && items.pluck(:generation).sort == expected_attempts
  puts "Recovered: one parent approval, each business once, two item audits and two independent pending effects"
else
  raise "Unknown probe mode"
end
