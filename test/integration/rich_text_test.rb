# frozen_string_literal: true

require "test_helper"
require "support/attachments"
require "tmpdir"

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
      assert_select "span.raa-label##{editor['id']}--label", text: "Body"
      assert_equal "#{editor['id']}--label", editor["aria-labelledby"]
      assert_select "script[src*='trix']"
      assert_select "link[rel=stylesheet][href*='trix']"
      html = %(<div>Hello <strong class="raa-danger" data-controller="evil">world</strong><script>alert(1)</script><img src="/sign_out" onerror="alert(2)"></div>)
      before_version = RailsAiAdmin::RecordVersion.of(@document)
      patch "/backoffice/documents/#{@document.id}", params: { intent_ref: intent, record: { title: "Handbook", body: html } }
      assert_response :see_other
      assert_operator RailsAiAdmin::RecordVersion.of(@document.reload), :>, before_version
      assert_includes @document.body.to_s, "world"
      assert_equal [ "body" ], RailsAiAdmin::AuditEvent.where(status: "succeeded").last.changed_fields

      get "/backoffice/documents/#{@document.id}"
      assert_select "div.raa-rich-text strong", text: "world"
      assert_select "div.raa-rich-text script", count: 0
      assert_select "div.raa-rich-text img", count: 0
      assert_select "div.raa-rich-text [data-controller]", count: 0
      assert_select "div.raa-rich-text .raa-danger", count: 0
      refute_includes response.body, "onerror"
      refute_includes response.body, "<script>alert(1)"

      get "/backoffice/documents/#{@document.id}/edit"
      hidden_val = css_select("input[name='record[body]']").first["value"]
      assert_includes hidden_val, "<strong>world</strong>"
      refute_includes hidden_val, "<img"
      refute_includes hidden_val, "data-controller"
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

  # Trix boots on the first full page, under that page's CSP nonce, rather
  # than on an edit page reached by a Turbo visit (whose nonce the browser
  # does not enforce). Admins without rich text do not load it.
  def test_layout_loads_trix_on_every_page_only_when_a_resource_has_rich_text
    with_document_resources do |registry|
      assert registry.rich_text?
      get "/backoffice/documents"
      assert_response :success
      assert_select "head script[src*='trix'][defer]", count: 1
      assert_select "head link[rel=stylesheet][href*='trix']", count: 1
    end
    with_document_resources do
      get "/backoffice/documents/#{@document.id}/edit"
      assert_select "head script[src*='trix']", count: 1
      # Loading it again beside the editor would rerun it on each Turbo visit.
      assert_select "body script[src*='trix']", count: 0
    end
    refute RailsAiAdmin.registry.rich_text?
    get "/backoffice"
    assert_response :success
    # The csp-nonce meta authorizes styles only. Turbo copies it onto inline
    # scripts it renders (hotwired/turbo#1476); without a script nonce they
    # still cannot run.
    policy = response.headers["Content-Security-Policy"]
    assert_includes policy, "script-src 'self';"
    assert_match(/style-src 'self' 'nonce-[^']+';/, policy)
    assert_equal css_select("meta[name=csp-nonce]").first["content"], policy[/style-src 'self' 'nonce-([^']+)'/, 1]
    assert_select "script[src*='trix']", count: 0
    assert_select "link[href*='trix']", count: 0
  end

  # A layout override copied before admin_rich_text_assets existed keeps a
  # working editor: the assets come with the field instead.
  def test_an_older_layout_override_still_loads_trix_beside_the_editor
    source = RailsAiAdmin::Engine.root.join("app/views/layouts/rails_ai_admin/application.html.erb").read
    Dir.mktmpdir("raa-layout-", File.expand_path("../../tmp", __dir__)) do |directory|
      path = File.join(directory, "layouts/rails_ai_admin/application.html.erb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source.sub("  <%= admin_rich_text_assets %>\n", "").tap { |older| refute_equal source, older })
      previous = RailsAiAdmin::ResourcesController.view_paths
      RailsAiAdmin::ResourcesController.prepend_view_path(directory)
      with_document_resources do
        get "/backoffice/documents/#{@document.id}/edit"
        assert_response :success
        assert_select "head script[src*='trix']", count: 0
        assert_select "body script[src*='trix'][defer]", count: 1
        assert_select "body link[rel=stylesheet][href*='trix']", count: 1
      end
    ensure
      RailsAiAdmin::ResourcesController.view_paths = previous if previous
    end
  end
end
