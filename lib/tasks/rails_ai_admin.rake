# frozen_string_literal: true

namespace :rails_ai_admin do
  desc "Report fail-closed installation and supported runtime boundaries (ONLY=errors or ONLY=review narrows the lines)"
  task doctor: :environment do
    require "rails_ai_admin/doctor"
    only = ENV.fetch("ONLY", "")
    abort "ONLY must be errors or review" unless [ "", "errors", "review" ].include?(only)
    checks = RailsAiAdmin::Doctor.new.checks
    shown = RailsAiAdmin::Doctor.select(checks, only)
    shown.each { |check| puts "[#{check.status}] #{check.name}: #{check.message}" }
    puts RailsAiAdmin::Doctor.summary(checks)
    abort "Resolve errors before enabling writes." if checks.any? { |check| check.status == :error }
  end

  desc "Delete proposed intents and selections that expired more than DAYS (default 7) days ago"
  task prune: :environment do
    require "rails_ai_admin/prune"
    days = ENV.fetch("DAYS", "7")
    abort "DAYS must be a whole number of days" unless days.match?(/\A\d{1,4}\z/)
    result = RailsAiAdmin::Prune.new(older_than: days.to_i.days).call
    puts "Deleted #{result.intents} expired intents and #{result.selections} expired selections."
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
