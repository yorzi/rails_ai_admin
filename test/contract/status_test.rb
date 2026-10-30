# frozen_string_literal: true

require "test_helper"

class StatusTest < Minitest::Test
  def test_statuses_are_immutable_fixed_text_and_do_not_accept_an_exception_message
    RailsAiAdmin::Presentation::Status::DEFINITIONS.each do |kind, values|
      status = RailsAiAdmin::Presentation::Status.fetch(kind)
      assert_equal values.first, status.http_status
      assert status.frozen?
      assert status.kind.frozen?
      assert status.code.frozen?
      assert status.title.frozen?
      assert status.message.frozen?
    end
    [ "private SQL exception", StandardError.new("private exception"), 404, nil ].each do |input|
      assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Presentation::Status.fetch(input) }
    end
  end

  def test_default_denial_codes_do_not_reveal_a_forbidden_record
    %w[FORBIDDEN private_failure NOT_FOUND].each do |code|
      status = RailsAiAdmin::Presentation::Status.for_code(code)
      assert_equal 404, status.http_status
      assert_equal "NOT_FOUND", status.code
      refute_includes status.message, code unless code == "NOT_FOUND"
    end
    assert_equal 403, RailsAiAdmin::Presentation::Status.fetch(:forbidden).http_status
    assert_equal 401, RailsAiAdmin::Presentation::Status.for_code("UNAUTHENTICATED").http_status
  end
end
