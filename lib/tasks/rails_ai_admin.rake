# frozen_string_literal: true

namespace :rails_ai_admin do
  desc "Report fail-closed installation and supported runtime boundaries"
  task doctor: :environment do
    require "rails_ai_admin/doctor"
    checks = RailsAiAdmin::Doctor.new.checks
    checks.each { |check| puts "[#{check.status}] #{check.name}: #{check.message}" }
    abort "Resolve errors before enabling writes." if checks.any? { |check| check.status == :error }
  end
end
