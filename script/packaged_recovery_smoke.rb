# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require_relative "support/disposable_database"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-devise-postgres")
url = DisposableDatabase.validate!(ENV.fetch("RAA_HOST_B_DATABASE_URL"))
raise "Run packaged_support_smoke first" unless File.file?(File.join(target, "Gemfile.lock"))
FileUtils.cp_r(Dir[File.join(root, "spec_hosts/devise_postgres/test/*")], File.join(target, "test"))
env = { "BUNDLE_GEMFILE" => File.join(target, "Gemfile"), "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
  "BUNDLE_APP_CONFIG" => File.join(target, ".bundle"), "RAILS_ENV" => "test", "RAA_HOST_B_DATABASE_URL" => url,
  "RAA_ASSET_PIPELINE" => ENV.fetch("RAA_ASSET_PIPELINE", "propshaft") }

def run!(env, target, *args)
  Bundler.with_unbundled_env { raise "Probe failed" unless system(env, "bundle", "exec", "ruby", *args, chdir: target) }
end

run!(env.merge("RAILS_ENV" => "development"), target, "test/reload_probe.rb")
run!(env, target, "test/recovery_probe.rb", "prepare")
run!(env, target, "test/recovery_probe.rb", "commit_and_exit")
run!(env, target, "test/recovery_probe.rb", "verify_replay")
run!(env, target, "test/recovery_probe.rb", "prepare")
ready_file = File.join(target, "tmp/recovery.ready")
log_path = File.join(target, "tmp/recovery-child.log")
FileUtils.mkdir_p(File.dirname(log_path))
reader, writer = IO.pipe
pid = nil
begin
  Bundler.with_unbundled_env do
    pid = Process.spawn(env, "bundle", "exec", "ruby", "test/recovery_probe.rb", "pause_before_commit",
      chdir: target, in: reader, out: log_path, err: [ :child, :out ])
  end
  reader.close
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  loop do
    if Process.waitpid(pid, Process::WNOHANG)
      pid = nil
      raise "Child exited before the crash point"
    end
    break if File.exist?(ready_file)
    raise "Timed out waiting for the live child" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.05
  end
  Process.kill("KILL", pid)
  Process.waitpid(pid)
  pid = nil
ensure
  reader.close unless reader.closed?
  writer.close
  if pid
    begin
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
  end
end
run!(env, target, "test/recovery_probe.rb", "verify_rollback")
run!(env, target, "test/recovery_probe.rb", "commit_and_exit")
run!(env, target, "test/recovery_probe.rb", "verify_replay")
puts "Packaged reload/crash/replay probes passed; no child remains running"

[
  [ "triage", "after", "succeeded", "2" ],
  [ "close", "before", "succeeded", "1" ],
  [ "close", "after", "reconciliation_required", "1" ]
].each do |decision, boundary, expected, requests|
  run!(env, target, "test/outbox_recovery_probe.rb", "prepare", decision)
  fault = boundary == "after" ? "RAA_FIXTURE_EXIT_AFTER_EFFECT" : "RAA_FIXTURE_EXIT_BEFORE_EFFECT"
  run!(env.merge(fault => "1"), target, "test/outbox_recovery_probe.rb", "deliver")
  run!(env, target, "test/outbox_recovery_probe.rb", "verify_crash", boundary)
  run!(env, target, "test/outbox_recovery_probe.rb", "wait_for_lease")
  run!(env, target, "test/outbox_recovery_probe.rb", "deliver")
  run!(env, target, "test/outbox_recovery_probe.rb", "verify_result", expected, requests)
end
puts "Packaged outbox death/retry/reconciliation probes passed against the synthetic downstream; no provider/network call or child remains"
