# frozen_string_literal: true

require "test_helper"
require "support/attachments"

# has_many_attached through a files field: add, remove, bound and download.
class FilesFieldsIntegrationTest < ActionDispatch::IntegrationTest
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
    patch "/backoffice/documents/#{@document.id}", params: { intent_ref: intent, record: { title: "Handbook" }.merge(record) }.merge(extra)
  end

  def png(name) = upload(PNG, name, "image/png")

  def test_add_show_download_and_remove_files
    with_document_resources do
      get "/backoffice/documents/#{@document.id}/edit"
      assert_select "input[type=file][multiple][name='record[photos][]'][accept='image/*']"
      before = RailsAiAdmin::RecordVersion.of(@document.reload)
      submit(photos: [ "", png("a.png"), png("b.png") ])
      assert_response :see_other
      assert_equal %w[a.png b.png], @document.reload.photos.map { |photo| photo.filename.to_s }.sort
      assert_operator RailsAiAdmin::RecordVersion.of(@document), :>, before
      assert_equal [ "photos" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields

      first = @document.photos.attachments.order(:id).first
      get "/backoffice/documents/#{@document.id}"
      path = "/backoffice/documents/#{@document.id}/files/photos?attachment=#{first.id}"
      assert_select "ul.raa-file-list a[href='#{path}']", text: /a\.png/
      assert_select "ul.raa-file-list img.raa-file-preview", count: 2
      get path
      assert_response :success
      assert_equal PNG.b, response.body.b

      submit({ photos: [ "", png("c.png") ] }, remove_attachments: { photos: [ first.id.to_s ] })
      assert_response :see_other
      assert_equal %w[b.png c.png], @document.reload.photos.map { |photo| photo.filename.to_s }.sort
      get path
      assert_response :not_found

      get "/backoffice/documents"
      assert_select "td", text: "2 files", count: 0, message: "files stay off lists by default"
    end
  end

  def test_bounds_types_and_foreign_attachments_are_refused
    other = Document.create!(account_id: 1, title: "Other")
    other.photos.attach(io: StringIO.new(PNG), filename: "theirs.png", content_type: "image/png")
    with_document_resources do
      submit(photos: [ "", png("1.png"), png("2.png"), png("3.png"), png("4.png") ])
      assert_response :unprocessable_content
      assert_select "p.raa-field-error", text: "can hold at most 3 files"
      submit(photos: [ "", upload(PDF, "x.png", "image/png") ])
      assert_select "p.raa-field-error", text: "is not an accepted file type"
      submit({}, remove_attachments: { photos: [ other.photos.attachments.first.id.to_s ] })
      assert_response :unprocessable_content
      assert_equal 1, other.reload.photos.count
      assert_equal 0, @document.reload.photos.count
      submit(photos: [ "", "a-signed-id" ])
      assert_response :unprocessable_content
      submit({}, remove_attachments: { title: [ "1" ] })
      assert_response :unprocessable_content
    end
  end
end
