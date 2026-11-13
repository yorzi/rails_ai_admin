# frozen_string_literal: true

require "test_helper"
require "support/essentials"
require "minitest/mock"
require "rails_ai_admin/doctor"

# time, email, url, json and the write-only password type.
class EverydayFieldTypesTest < Minitest::Test
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @runner = RailsAiAdmin::Operations::Runner.new
  end

  def field(type, **options) = RailsAiAdmin::Field.new(:value, type: type, **options)

  def assert_rejected(field, value, message)
    error = assert_raises(ArgumentError) { field.coerce(value) }
    assert_equal message, error.message
  end

  def test_time_of_day_is_canonical_text
    time = field(:time)
    assert_equal "09:05:00", time.coerce("09:05")
    assert_equal "23:59:30", time.coerce("23:59:30")
    assert_equal "07:15:00", time.coerce_output(Time.utc(2000, 1, 1, 7, 15))
    [ "24:00", "9:05", "12:60", "noon", "12:00:00Z" ].each { |value| assert_rejected(time, value, "must be a time of day (HH:MM)") }
    assert_equal "07:15", time.format(Time.utc(2000, 1, 1, 7, 15))
    assert_equal "07:15:09", time.format("07:15:09")
    assert JSONSchemer.schema(time.json_schema).valid?("07:15")
    refute JSONSchemer.schema(time.json_schema).valid?("7:15")
    assert_raises(RailsAiAdmin::ConfigurationError) { field(:time, filterable: true) }
    assert_raises(RailsAiAdmin::ConfigurationError) { field(:time, searchable: true) }
  end

  def test_email_and_url_are_checked_text
    email = field(:email)
    assert_equal "ada@example.com", email.coerce("ada@example.com")
    [ "ada", "ada@", "@example.com", "ada example@x.com" ].each { |value| assert_rejected(email, value, "must be an email address") }
    url = field(:url)
    assert_equal "https://example.com/a?b=1", url.coerce("https://example.com/a?b=1")
    assert_equal "HTTP://EXAMPLE.COM", url.coerce("HTTP://EXAMPLE.COM")
    [ "javascript:alert(1)", "example.com", "ftp://example.com", "https://", "https://exa mple.com", "data:text/html,x" ].each do |value|
      assert_rejected(url, value, "must be an http or https address")
    end
    refute url.web_address?("javascript://example.com/%0Aalert(1)")
    assert_equal %i[eq], field(:email, filterable: true).filter_operators
  end

  def test_json_accepts_documents_within_bounds
    json = field(:json)
    assert_equal({ "a" => [ 1, true, nil ] }, json.coerce('{"a":[1,true,null]}'))
    assert_equal [ 1, 2 ], json.coerce([ 1, 2 ])
    assert_equal({ "b" => 1.5 }, json.coerce({ "b" => 1.5 }))
    [ "{", "{'a':1}", "NaN" ].each { |value| assert_rejected(json, value, "must be valid JSON") }
    assert_rejected(json, { a: 1 }, "must be valid JSON")
    assert_rejected(json, ("[" * 40) + ("]" * 40), "must be valid JSON")
    assert_rejected(field(:json, max_length: 10), '{"a":"long text"}', "is too long")
    assert_nil json.coerce("  ")
    assert_includes json.format({ "a" => 1 }), "\n"
    assert_raises(RailsAiAdmin::ConfigurationError) { field(:json, sortable: true) }
    assert_raises(RailsAiAdmin::ConfigurationError) { field(:json, filterable: true) }
  end

  def test_password_is_write_only_and_never_stored_in_a_digest
    password = field(:password)
    secret = password.coerce("correct horse")
    assert_kind_of RailsAiAdmin::Field::Secret, secret
    assert_equal "[FILTERED]", secret.inspect
    refute password.visible_on?(:index)
    refute password.visible_on?(:show)
    assert_rejected(password, nil, "cannot be blank")
    digest = RailsAiAdmin::InputSchema.digest("password" => secret)
    refute_equal Digest::SHA256.hexdigest(JSON.generate("password" => "correct horse")), digest
    refute_includes JSON.generate(RailsAiAdmin::InputSchema.canonical("password" => secret)), "correct horse"
    assert_equal digest, RailsAiAdmin::InputSchema.digest("password" => password.coerce("correct horse"))
    # An empty box is "keep the current password", not a blank value.
    result = RailsAiAdmin::InputSchema.new([ password ], partial: true).coerce({ "value" => "" })
    assert result.valid?
    assert_empty result.values
    [ { searchable: true }, { sortable: true }, { filterable: true }, { show: true }, { index: true }, { readonly: true } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError, options.inspect) { field(:password, **options) }
    end
    operation = Class.new(RailsAiAdmin::Operation)
    assert_raises(RailsAiAdmin::ConfigurationError) { operation.input { password(:pin) } }
  end

  def test_no_grant_reveals_a_password
    with_essential_resources do |registry|
      access = RailsAiAdmin::Authorization::Access.new(context, registry.fetch(:articles))
      refute_includes access.fields(:read, @article).map(&:name), :password
      refute access.project(@article).key?("password")
      assert_includes access.fields(:write, @article, operation: :update).map(&:name), :password
      password = registry.fetch(:articles).fields.find { |entry| entry.name == :password }
      assert_raises(RailsAiAdmin::AccessDenied) { access.read_attribute(@article, password) }
    end
  end

  def test_runner_writes_every_new_type_and_audits_a_password_change_by_name
    with_essential_resources do |registry|
      resource = registry.fetch(:articles)
      intent = @runner.prepare(context: context, resource: resource, operation: :update, target_id: @article.id,
        expected_version: RailsAiAdmin::RecordVersion.of(@article))
      input = { "contact" => "ada@example.com", "website" => "https://example.com", "opens_at" => "08:30",
        "settings" => '{"theme":"dark","limits":[1,2]}', "password" => "a long password" }
      result = @runner.execute(context: context, intent_ref: intent.id, input: input, human_confirmed: true)
      assert result.success?, result.inspect
      @article.reload
      assert_equal "ada@example.com", @article.contact
      assert_equal "08:30", @article.opens_at.strftime("%H:%M")
      assert_equal({ "theme" => "dark", "limits" => [ 1, 2 ] }, @article.settings)
      assert @article.authenticate("a long password")
      audit = RailsAiAdmin::AuditEvent.find(result.audit_ref)
      assert_equal %w[contact opens_at password settings website], audit.changed_fields.sort
      run = intent.reload
      refute_includes run.attributes.to_json, "a long password"
      refute_includes audit.attributes.to_json, "a long password"
      refute result.values.key?("password")

      # A blank password box keeps the stored digest.
      digest = @article.password_digest
      intent = @runner.prepare(context: context, resource: resource, operation: :update, target_id: @article.id,
        expected_version: RailsAiAdmin::RecordVersion.of(@article))
      result = @runner.execute(context: context, intent_ref: intent.id, input: { "title" => "Renamed", "password" => "" }, human_confirmed: true)
      assert result.success?, result.inspect
      assert_equal digest, @article.reload.password_digest
      assert_equal [ "title" ], RailsAiAdmin::AuditEvent.find(result.audit_ref).changed_fields
    end
  end

  def test_doctor_accepts_the_new_columns_and_suggestions_name_them
    with_essential_resources do |registry|
      checks = RailsAiAdmin::Doctor.new(application: nil, registry: registry).checks
      schema = checks.find { |entry| entry.name == "schema:articles" }
      assert_equal :ok, schema.status, schema.message
      types = checks.find { |entry| entry.name == "field_types:articles" }
      assert_equal :ok, types.status, types.message
      assert_equal :ok, checks.find { |entry| entry.name == "resource:articles" }.status
    end
    suggestions = RailsAiAdmin::SchemaSuggestions.new(Article).call.suggestions.to_h { |entry| [ entry.name, entry.type ] }
    assert_equal :text, suggestions.fetch("contact"), "only email-like names suggest email"
    assert_equal :url, suggestions.fetch("website")
    assert_equal :time, suggestions.fetch("opens_at")
    assert_equal :json, suggestions.fetch("settings")
    refute suggestions.key?("password_digest")
  end
end
