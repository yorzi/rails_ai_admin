# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require_relative "support/disposable_database"

root = File.expand_path("..", __dir__)
target = File.join(root, "tmp/packaged-devise-postgres")
url = DisposableDatabase.validate!(ENV.fetch("RAA_HOST_B_DATABASE_URL"))
raise "Run packaged_support_smoke first" unless File.file?(File.join(target, "Gemfile.lock"))
FileUtils.cp(File.join(root, "spec_hosts/devise_postgres/test/collection_recovery_probe.rb"), File.join(target, "test/collection_recovery_probe.rb"))
env = { "BUNDLE_GEMFILE" => File.join(target, "Gemfile"), "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
  "BUNDLE_APP_CONFIG" => File.join(target, ".bundle"), "RAILS_ENV" => "test", "RAA_HOST_B_DATABASE_URL" => url,
  "RAA_ASSET_PIPELINE" => ENV.fetch("RAA_ASSET_PIPELINE", "propshaft") }

def run!(env, target, *args)
  Bundler.with_unbundled_env do
    raise "Collection recovery probe failed" unless system(env, "bundle", "exec", "ruby", "test/collection_recovery_probe.rb", *args, chdir: target)
  end
end

%w[claim_and_exit pause_before_commit commit_then_exit].each do |boundary|
  run!(env, target, "prepare")
  if boundary == "pause_before_commit"
    reader, writer = IO.pipe
    pid = nil
    ready = File.join(target, "tmp/collection-recovery.ready")
    begin
      Bundler.with_unbundled_env do
        pid = Process.spawn(env, "bundle", "exec", "ruby", "test/collection_recovery_probe.rb", boundary,
          chdir: target, in: reader, out: File.join(target, "tmp/collection-recovery-child.log"), err: [ :child, :out ])
      end
      reader.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      loop do
        if Process.waitpid(pid, Process::WNOHANG)
          pid = nil
          raise "Child exited before the confirmed crash point"
        end
        break if File.exist?(ready)
        raise "Timed out waiting for live item transaction" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
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
  else
    run!(env, target, boundary)
  end
  if boundary == "commit_then_exit"
    run!(env, target, "verify_committed")
  else
    run!(env, target, "verify_uncommitted")
    run!(env, target, "wait_for_lease")
  end
  run!(env, target, "deliver")
  run!(env, target, "verify_completed", boundary == "commit_then_exit" ? "committed" : "reclaimed")
end
puts "Packaged collection process-loss recovery passed; no child/server or provider call remains"
