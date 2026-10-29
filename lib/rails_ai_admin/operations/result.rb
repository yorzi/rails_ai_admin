# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    # Returns safe refs and a current authorized projection, never an AR object.
    class Result
      attr_reader :code, :record_id, :audit_ref, :values, :errors, :replayed, :warning, :work_refs

      def initialize(code:, record_id: nil, audit_ref: nil, values: {}, errors: {}, replayed: false, warning: nil, work_refs: [])
        @code, @record_id, @audit_ref, @warning = code, record_id, audit_ref, warning
        @values, @errors, @replayed = values.freeze, errors.freeze, replayed
        @work_refs = work_refs.freeze
        freeze
      end

      def success? = code == "OK"
      def retryable? = code == "CONFLICT"
      def status = success? ? :succeeded : :rejected
    end
  end
end
