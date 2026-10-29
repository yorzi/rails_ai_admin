# frozen_string_literal: true

require "uri"

# Validates the explicit disposable target used by destructive host fixtures.
module DisposableDatabase
  MESSAGE = "Use a PostgreSQL URL with a simple database name ending in _test and no query or fragment".freeze

  def self.validate!(value)
    raise ArgumentError, MESSAGE unless value.is_a?(String)
    uri = URI.parse(value)
    database = URI.decode_www_form_component(uri.path.to_s.delete_prefix("/"))
    valid = %w[postgres postgresql].include?(uri.scheme) && uri.host &&
      uri.query.nil? && uri.fragment.nil? && database.match?(/\A[a-zA-Z0-9_]+_test\z/)
    raise ArgumentError, MESSAGE unless valid
    value
  rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError
    # Invalid URI exceptions may contain userinfo, so do not propagate their text.
    raise ArgumentError, MESSAGE, cause: nil
  end
end
