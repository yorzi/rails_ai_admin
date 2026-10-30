# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    class Result
      attr_reader :code, :job_ref, :status, :errors, :replayed, :warning
      def initialize(code:, job_ref: nil, status: "rejected", errors: {}, replayed: false, warning: nil)
        @code, @job_ref, @status, @errors, @replayed, @warning = code, job_ref, status, errors.freeze, replayed, warning
        freeze
      end
      def accepted? = job_ref.present? && %w[QUEUED OK].include?(code)
      def success? = status == "succeeded"
    end
  end
end
