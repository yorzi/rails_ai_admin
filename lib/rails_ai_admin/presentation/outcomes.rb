# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # One table from stable result codes to the sentence a person reads
    # (RAA-027). The code stays available as secondary text for support, but no
    # page should show a bare code as its explanation.
    module Outcomes
      SENTENCES = {
        "OK" => "Done.",
        "VALIDATION_FAILED" => "Some values need attention.",
        "CONFLICT" => "The record changed after this page was opened.",
        "RESTRICTED" => "The record is still in use and cannot be deleted.",
        "NOT_FOUND" => "The record is not available.",
        "UNAUTHENTICATED" => "Sign in to continue.",
        "INVALID_QUERY" => "The list settings are not available.",
        "APPROVAL_REQUIRED" => "This change needs your explicit confirmation.",
        "APPROVAL_EXPIRED" => "This form expired before it was submitted.",
        "APPROVAL_INVALIDATED" => "Your access or the operation changed after this form was opened.",
        "IDEMPOTENCY_CONFLICT" => "This form was already submitted with different values.",
        "AUTHORIZATION_REVOKED" => "Your access changed before the work ran.",
        "SELECTION_INVALIDATED" => "The selection no longer matches the records.",
        "SELECTION_EXPIRED" => "The selection expired.",
        "TIMEOUT" => "The operation took too long and was stopped.",
        "OPERATION_FAILED" => "The operation failed.",
        "POST_COMMIT_CALLBACK_FAILED" => "The change was saved, but a follow-up step failed.",
        "OUTCOME_UNKNOWN" => "The result could not be confirmed.",
        "ATTEMPTS_EXHAUSTED" => "The work failed after several attempts.",
        "CANCELLED" => "The work was cancelled.",
        "EXECUTION_EXPIRED" => "The work expired before it could run.",
        "WORK_EXPIRED" => "The work expired before it could run.",
        "HANDLER_CHANGED" => "The operation changed after the work was queued.",
        "UNAVAILABLE" => "This is not available right now."
      }.freeze

      def self.sentence(code)
        SENTENCES.fetch(code.to_s) { "The request could not be completed." }
      end
    end
  end
end
