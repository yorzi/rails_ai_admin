# frozen_string_literal: true

require "test_helper"
require "support/attachments"
require "rails_ai_admin/doctor"

# The file field contract: only new, unattached blobs that fit the declaration.
class FileFieldContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AttachmentFixtures

  def setup
    reset_database
    reset_documents
  end

  def blob(content, name, type) = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename: name, content_type: type)

  def test_coercion_checks_blob_state_type_and_size
    field = RailsAiAdmin::Field.new(:cover, type: :file, accept: %w[image/* application/pdf], max_size: 100)
    png = blob(PNG, "a.png", "image/png")
    assert_equal png.signed_id, field.coerce(png.signed_id)
    assert_nil field.coerce(nil)
    pdf = blob(PDF, "a.pdf", "application/pdf")
    assert_equal pdf.signed_id, field.coerce(pdf.signed_id)
    text = blob("plain", "a.txt", "text/plain")
    assert_equal "is not an accepted file type", assert_raises(ArgumentError) { field.coerce(text.signed_id) }.message
    large = blob("x" * 101, "b.png", "image/png")
    assert_match(/is larger than 100 Bytes/, assert_raises(ArgumentError) { field.coerce(large.signed_id) }.message)
    @document.cover.attach(png)
    assert_equal "is not an available upload", assert_raises(ArgumentError) { field.coerce(png.signed_id) }.message
    assert_equal "is not an available upload", assert_raises(ArgumentError) { field.coerce("forged--id") }.message
    assert_raises(ArgumentError) { field.coerce(42) }
  end

  def test_declarations_are_bounded
    assert_equal 10 * 1024 * 1024, RailsAiAdmin::Field.new(:cover, type: :file).options[:max_size]
    [ { accept: "image/png" }, { accept: [ "png" ] }, { max_size: 0 }, { sortable: true }, { searchable: true }, { filterable: true } ].each do |options|
      assert_raises(RailsAiAdmin::ConfigurationError, options.inspect) { RailsAiAdmin::Field.new(:cover, type: :file, **options) }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:title, type: :text, accept: %w[image/png]) }
    operation = Class.new(RailsAiAdmin::Operation)
    assert_raises(RailsAiAdmin::ConfigurationError) { operation.input { file(:upload) } }
  end

  def test_reads_audits_and_doctor_know_attachments
    with_document_resources do |registry|
      resource = registry.fetch(:documents)
      access = RailsAiAdmin::Authorization::Access.new(context, resource)
      assert_nil access.project(@document)["cover"]
      @document.cover.attach(io: StringIO.new(PNG), filename: "c.png", content_type: "image/png")
      value = access.project(@document.reload)["cover"]
      assert_equal [ "c.png", "image/png", PNG.bytesize ], [ value.filename, value.content_type, value.byte_size ]
      assert value.image?
      checks = RailsAiAdmin::Doctor.new(application: nil, registry: registry).checks
      assert_equal :ok, checks.find { |entry| entry.name == "schema:documents" }.status
      runner = RailsAiAdmin::Operations::Runner.new
      upload = blob(PDF, "terms.pdf", "application/pdf")
      intent = runner.prepare(context: context, resource: resource, operation: :update, target_id: @document.id,
        expected_version: RailsAiAdmin::RecordVersion.of(@document))
      result = runner.execute(context: context, intent_ref: intent.id, input: { "contract" => upload.signed_id }, human_confirmed: true)
      assert result.success?, result.inspect
      assert_equal [ "contract" ], RailsAiAdmin::AuditEvent.find(result.audit_ref).changed_fields
      assert_equal "terms.pdf", result.values["contract"].filename
    end
  end
end
