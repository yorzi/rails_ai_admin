# frozen_string_literal: true

namespace :rails_ai_admin do
  desc "Report fail-closed installation and supported runtime boundaries"
  task doctor: :environment do
    require "rails_ai_admin/doctor"
    checks = RailsAiAdmin::Doctor.new.checks
    checks.each { |check| puts "[#{check.status}] #{check.name}: #{check.message}" }
    abort "Resolve errors before enabling writes." if checks.any? { |check| check.status == :error }
  end

  namespace :collections do
    desc "Enqueue up to 100 due collection runs; schedule recurring scans in the host"
    task scan: :environment do
      puts "Scheduled #{RailsAiAdmin::Collections::Dispatcher.new.scan_pending!} collection runs."
    end

    desc "Visit up to 100 collection runs inline; each target commits separately"
    task drain: :environment do
      puts "Visited #{RailsAiAdmin::Collections::Dispatcher.new.scan_pending!(inline: true)} collection runs."
    end
  end

  namespace :assistant do
    desc "Enqueue up to 100 chats with due assistant turns; schedule recurring scans in the host"
    task scan: :environment do
      require "rails_ai_admin/assistant"
      puts "Scheduled #{RailsAiAdmin::Assistant::Coordinator.new.scan_pending!} assistant chats."
    end

    desc "Run due assistant turns of up to 100 chats inline, outside web requests"
    task drain: :environment do
      require "rails_ai_admin/assistant"
      puts "Visited #{RailsAiAdmin::Assistant::Coordinator.new.scan_pending!(inline: true)} assistant chats."
    end
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
