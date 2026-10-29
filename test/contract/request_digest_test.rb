# frozen_string_literal: true

require "test_helper"

class RequestDigestTest < Minitest::Test
  def test_request_fingerprint_sorts_json_objects_without_typed_marker_collisions
    digest = RailsAiAdmin::Outbox::RequestDigest
    assert_equal digest.call(b: [ 1, false, nil ], a: { z: "value" }), digest.call("a" => { "z" => "value" }, "b" => [ 1, false, nil ])
    refute_equal digest.call(amount: "1.0"), digest.call(amount: { "$decimal" => "1.0" })
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(amount: BigDecimal("1.0")) }
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(at: Time.now) }
  end

  def test_duplicate_keys_non_finite_values_depth_and_size_are_rejected
    digest = RailsAiAdmin::Outbox::RequestDigest
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(a: 1, "a" => 2) }
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(nested: { a: 1, "a" => 2 }) }
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(number: Float::NAN) }
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(text: "x" * 16_385) }
    recursive = {}
    recursive[:self] = recursive
    assert_raises(RailsAiAdmin::ConfigurationError) { digest.call(recursive) }
  end
end
