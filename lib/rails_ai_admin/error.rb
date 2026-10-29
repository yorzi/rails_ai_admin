# frozen_string_literal: true

module RailsAiAdmin
  # Identifies a configuration that cannot safely serve administrative requests.
  class ConfigurationError < StandardError; end

  # Carries a stable, non-sensitive failure code across the execution boundary.
  class AccessDenied < StandardError
    attr_reader :code

    def initialize(code = "NOT_FOUND")
      @code = code
      super(code)
    end
  end
end
