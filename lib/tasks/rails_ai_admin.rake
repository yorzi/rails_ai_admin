# frozen_string_literal: true

namespace :rails_ai_admin do
  desc "Report fail-closed installation and supported runtime boundaries"
  task doctor: :environment do
    require "rails_ai_admin/doctor"
    checks = RailsAiAdmin::Doctor.new.checks
    checks.each { |check| puts "[#{check.status}] #{check.name}: #{check.message}" }
    abort "Resolve errors before enabling writes." if checks.any? { |check| check.status == :error }
  end

  namespace :work do
    desc "Enqueue up to 100 due outbox items; schedule recurring scans in the host"
    task scan: :environment do
      puts "Scheduled #{RailsAiAdmin::Outbox::Dispatcher.new.scan_pending!} outbox items."
    end

    desc "Deliver up to 100 due outbox items inline, outside domain transactions"
    task drain: :environment do
      puts "Visited #{RailsAiAdmin::Outbox::Dispatcher.new.scan_pending!(inline: true)} outbox items."
    end
  end
end
