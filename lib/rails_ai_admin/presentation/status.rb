# frozen_string_literal: true

module RailsAiAdmin
  module Presentation
    # Fixed public status text. Exceptions, params and record values are not inputs.
    class Status < Data.define(:kind, :http_status, :code, :title, :message)
      DEFINITIONS = {
        "authentication_required" => [ 401, "UNAUTHENTICATED", "Authentication required", "Sign in through the host application to continue." ].freeze,
        "forbidden" => [ 403, "FORBIDDEN", "Access unavailable", "Your current permissions do not allow this page." ].freeze,
        "not_found" => [ 404, "NOT_FOUND", "Not found", "This page or record is not available under your current access." ].freeze,
        "conflict" => [ 409, "CONFLICT", "The request has changed", "Review the current records and permissions before preparing a fresh request." ].freeze,
        "invalid_query" => [ 422, "INVALID_QUERY", "Invalid query", "Open a fresh list and use the available search, sort and page settings." ].freeze,
        "invalid_request" => [ 422, "INVALID_REQUEST", "Invalid request", "Your session or request could not be verified. Sign in and review a fresh form before submitting." ].freeze,
        "unavailable" => [ 503, "UNAVAILABLE", "Administration unavailable", "Administration is not configured safely. Contact the host maintainer." ].freeze,
        "error" => [ 500, "ERROR", "The request needs review", "Check current records or existing operation results before retrying. A prior write may have completed." ].freeze
      }.freeze

      def self.fetch(kind)
        raise ConfigurationError, "Unknown status kind" unless kind.is_a?(String) || kind.is_a?(Symbol)
        key = kind.to_s
        values = DEFINITIONS.fetch(key) { raise ConfigurationError, "Unknown status kind" }
        new(String.new(key).freeze, *values)
      end

      def self.for_code(code)
        kind = case code
        when "UNAUTHENTICATED" then :authentication_required
        when "INVALID_QUERY" then :invalid_query
        when "CONFLICT", "SELECTION_EXPIRED", "SELECTION_INVALIDATED" then :conflict
        else :not_found
        end
        fetch(kind)
      end
    end
  end
end
