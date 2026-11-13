# frozen_string_literal: true

require "test_helper"
require "support/attachments"

# Action Text rich text fields: Trix editing, sanitized display, plain lists.
class RichTextIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AttachmentFixtures

  def setup
    reset_database
    reset_documents
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_edit_save_show_and_list_rich_text
    with_document_resources do
      get "/backoffice/documents/#{@document.id}/edit"
      assert_response :success
      editor = css_select("trix-editor.raa-rich-text-editor").first
      assert editor
      hidden = css_select("input[type=hidden][name='record[body]']").first
      assert_equal hidden["id"], editor["input"]
      assert_select "label[for='#{editor['id']}']", text: "Body"
      assert_select "script[src*='trix']"
      assert_select "link[rel=stylesheet][href*='trix']"
      html = %(<div>Hello <strong>world</strong><script>alert(1)</script><img src=x onerror="alert(2)"></div>)
      patch "/backoffice/documents/#{@document.id}", params: { intent_ref: intent, record: { title: "Handbook", body: html } }
      assert_response :see_other
      assert_includes @document.reload.body.to_s, "<strong>world</strong>"
      assert_equal [ "body" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields

      get "/backoffice/documents/#{@document.id}"
      assert_select "div.raa-rich-text strong", text: "world"
      assert_select "div.raa-rich-text script", count: 0
      refute_includes response.body, "onerror"
      refute_includes response.body, "<script>alert(1)"

      get "/backoffice/documents/#{@document.id}/edit"
      assert_includes css_select("input[name='record[body]']").first["value"], "<strong>world</strong>"
      patch "/backoffice/documents/#{@document.id}", params: { intent_ref: intent, record: { title: "Handbook", body: "" } }
      assert_response :see_other
      assert @document.reload.body.to_plain_text.blank?
    end
  end

  def test_lists_show_plain_text_and_doctor_accepts_the_field
    @document.update!(body: "<p>First <em>line</em></p>")
    with_document_resources do |registry|
      get "/backoffice/documents"
      assert_select "td", text: "First line"
      refute_includes response.body, "<em>line</em>"
      require "rails_ai_admin/doctor"
      checks = RailsAiAdmin::Doctor.new(application: nil, registry: registry).checks
      assert_equal :ok, checks.find { |entry| entry.name == "schema:documents" }.status
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:body, type: :rich_text, searchable: true) }
    assert_equal 1_048_576, RailsAiAdmin::Field.new(:body, type: :rich_text).options[:max_length]
  end
end
