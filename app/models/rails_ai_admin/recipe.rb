# frozen_string_literal: true

module RailsAiAdmin
  class Recipe < ApplicationRecord
    self.table_name = "rails_ai_admin_recipes"
    has_many :runs, class_name: "RailsAiAdmin::RecipeRun", inverse_of: :recipe

    DEFINITION = %w[slug name instructions resource_key plan trigger_kind time_zone schedule_cron event_name overlap_policy max_runs_per_day owner_ref owner_epoch principal_ref principal_epoch].freeze
    validates :slug, format: { with: /\A[a-z][a-z0-9_]{0,63}\z/ }
    validates :name, length: { in: 1..80 }
    validates :instructions, length: { in: 1..4000 }
    validates :trigger_kind, inclusion: { in: %w[manual schedule event] }
    validates :overlap_policy, inclusion: { in: %w[skip queue_one] }
    validates :max_runs_per_day, numericality: { only_integer: true, in: 1..100 }
    validate :validate_definition
    before_save :revise

    def next_occurrence(after:)
      require "fugit"
      zone = ActiveSupport::TimeZone[time_zone]
      raise ConfigurationError, "Unknown schedule time zone" unless zone
      raise ConfigurationError, "Expected a five-field cron" unless schedule_cron.is_a?(String) && schedule_cron.bytesize <= 64 && schedule_cron.split.size == 5
      cron = Fugit::Cron.parse("#{schedule_cron} #{zone.tzinfo.name}")
      raise ConfigurationError, "Invalid recipe cron" unless cron
      cron.next_time(after.to_time).to_utc_time
    end

    private

    def validate_definition
      Recipes::Plan.validate!(self)
      if trigger_kind == "event"
        errors.add(:event_name, :invalid) unless RailsAiAdmin.configuration.recipe_events.include?(event_name)
      elsif event_name.present?
        errors.add(:event_name, :invalid)
      end
      if trigger_kind == "schedule"
        next_occurrence(after: Time.current)
      elsif schedule_cron.present?
        errors.add(:schedule_cron, :invalid)
      end
    rescue ConfigurationError, AccessDenied
      errors.add(:base, :invalid)
    end

    def revise
      revised = (changes_to_save.keys & (DEFINITION + [ "enabled" ])).any?
      self.version += 1 if persisted? && revised
      if revised || new_record?
        self.next_run_at = next_occurrence(after: Time.current) if trigger_kind == "schedule" && enabled?
        self.next_run_at = nil unless trigger_kind == "schedule" && enabled?
      end
    end
  end
end
