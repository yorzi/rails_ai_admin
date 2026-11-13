# frozen_string_literal: true

require "test_helper"
require "support/attachments"

# Active Storage file fields: upload, replace, remove and authorized download.
class FileFieldsIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AttachmentFixtures

  def setup
    reset_database
    reset_documents
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def submit(record, extra = {})
    get "/backoffice/documents/#{@document.id}/edit"
    patch "/backoffice/documents/#{@document.id}", params: { intent_ref: intent, record: record }.merge(extra)
  end

  def test_upload_show_download_replace_and_remove
    with_document_resources do
      get "/backoffice/documents/#{@document.id}/edit"
      assert_select "form[enctype='multipart/form-data']"
      assert_select "input[type=file][name='record[cover]'][accept='image/*']"
      assert_select "input[type=file][name='record[contract]'][accept='application/pdf']"
      submit({ title: "Handbook", cover: upload(PNG, "cover.png", "image/png") })
      assert_response :see_other
      assert_equal "cover.png", @document.reload.cover.filename.to_s
      assert_equal [ "cover" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields

      get "/backoffice/documents/#{@document.id}"
      path = "/backoffice/documents/#{@document.id}/files/cover"
      assert_select "img.raa-file-preview[src='#{path}?disposition=inline'][alt='cover.png']"
      assert_select "a[href='#{path}']", text: /cover\.png \(\d+ Bytes\)/
      refute_includes response.body, "/rails/active_storage"

      get path
      assert_response :success
      assert_equal "application/octet-stream", response.media_type
      assert_match(/\Aattachment; filename="cover.png"/, response.headers["Content-Disposition"])
      assert_equal PNG.b, response.body.b
      assert_includes response.headers["Content-Security-Policy"], "sandbox"
      get "#{path}?disposition=inline"
      assert_equal "image/png", response.media_type
      assert_match(/\Ainline/, response.headers["Content-Disposition"])

      get "/backoffice/documents/#{@document.id}/edit"
      assert_select "p.raa-file-current", text: /cover\.png/
      assert_select "input[type=checkbox][name='remove_files[]'][value=cover]"
      submit({ title: "Handbook" }, remove_files: [ "cover" ])
      assert_response :see_other
      refute @document.reload.cover.attached?
    end
  end

  def test_type_size_and_unchanged_submissions
    with_document_resources do
      submit({ title: "Handbook", cover: upload(PDF, "cover.png", "image/png") })
      assert_response :unprocessable_content
      assert_select "p.raa-field-error", text: "is not an accepted file type"
      refute @document.reload.cover.attached?
      assert_equal 0, ActiveStorage::Blob.where.not(id: ActiveStorage::Attachment.select(:blob_id)).where("created_at > ?", 1.minute.ago).count - enqueued_purges

      submit({ title: "Handbook", cover: upload("x" * (1024 * 1024 + 1), "big.png", "image/png") })
      assert_response :unprocessable_content
      assert_select "p.raa-field-error", text: "is larger than 1 MB"

      submit({ title: "Handbook", contract: upload(PDF, "terms.pdf", "application/pdf") })
      assert_response :see_other
      submit({ title: "Renamed", contract: "" })
      assert_response :see_other
      assert_equal "terms.pdf", @document.reload.contract.filename.to_s
      assert_equal [ "title" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields
    end
  end

  def test_pages_never_take_blob_ids_and_downloads_follow_grants
    other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PDF), filename: "elsewhere.pdf", content_type: "application/pdf")
    @document.cover.attach(io: StringIO.new(SVG), filename: "logo.svg", content_type: "image/svg+xml")
    with_document_resources do
      submit({ title: "Handbook", contract: other.signed_id })
      assert_response :unprocessable_content
      refute @document.reload.contract.attached?

      get "/backoffice/documents/#{@document.id}"
      assert_select "img.raa-file-preview", count: 0, message: "SVG is never shown inline"
      get "/backoffice/documents/#{@document.id}/files/cover?disposition=inline"
      assert_equal "application/octet-stream", response.media_type
      assert_match(/\Aattachment/, response.headers["Content-Disposition"])

      get "/backoffice/documents/#{@document.id}/files/contract"
      assert_response :not_found
      get "/backoffice/documents/#{@document.id}/files/title"
      assert_response :not_found
      AttachmentFixtures::Policy.read = %i[id title]
      get "/backoffice/documents/#{@document.id}/files/cover"
      assert_response :not_found
      AttachmentFixtures::Policy.reset!
      foreign = Document.create!(account_id: 2, title: "Other tenant")
      foreign.cover.attach(io: StringIO.new(PNG), filename: "secret.png", content_type: "image/png")
      get "/backoffice/documents/#{foreign.id}/files/cover"
      assert_response :not_found
    end
    post "/test/sign_in/2"
    with_document_resources do
      get "/backoffice/documents/#{@document.id}"
      assert_response :success
      get "/backoffice/documents/#{@document.id}/edit"
      assert_response :not_found
    end
  end

  private

  def enqueued_purges
    ActiveJob::Base.queue_adapter.respond_to?(:enqueued_jobs) ? ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActiveStorage::PurgeJob } : 0
  end
end
