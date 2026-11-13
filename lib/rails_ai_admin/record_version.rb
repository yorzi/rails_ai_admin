# frozen_string_literal: true

module RailsAiAdmin
  # The optimistic version a form, intent, selection or work item carries for
  # one record. Models with Rails optimistic locking use lock_version. Other
  # models use updated_at, as whole microseconds since the epoch, compared
  # after the record is loaded with a row lock inside the write transaction.
  module RecordVersion
    STRATEGIES = %i[lock_version updated_at].freeze

    module_function

    # :lock_version, :updated_at or nil when the model cannot carry a version.
    def strategy(model)
      return :lock_version if model.locking_enabled? && model.locking_column == "lock_version"
      column = model.columns_hash["updated_at"]
      return :updated_at if column && %i[datetime timestamp].include?(column.type) && model.record_timestamps
      nil
    end

    def supported?(model)
      !strategy(model).nil? && !model.composite_primary_key?
    end

    # A nonnegative Integer. A record whose updated_at is still NULL is
    # version 0 until its first write sets it.
    def of(record)
      case strategy(record.class)
      when :lock_version then record.lock_version
      when :updated_at
        time = record.read_attribute("updated_at")
        time.nil? ? 0 : (time.to_r * 1_000_000).to_i
      else raise ConfigurationError, "Writes require lock_version or an updated_at timestamp"
      end
    end

    # The column a resource must never let a person write directly.
    def column(model) = strategy(model)&.to_s
  end
end
