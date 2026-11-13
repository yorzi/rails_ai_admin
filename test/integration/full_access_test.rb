# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"
require "rails_ai_admin/test_kit"
require "rails_ai_admin/doctor"
require "tmpdir"

# The opt-in trusted-staff preset: declared exposure is the whole policy.
class FullAccessTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  PRESET = "RailsAiAdmin::Authorization::FullAccessAdapter"

  class TenantPolicy < RailsAiAdmin::Authorization::FullAccessAdapter
    def scope(context:, resource:, relation:) = relation.where(account_id: context.tenant.id)
    def allowed?(context:, action:, resource:, record: nil) = context.actor.id == 1 || %i[index show].include?(action)
  end

  class Labelled
    attr_reader :id
    def initialize(id) = @id = id
    def email = "  staff#{id}@example.test  "
    def secret = :not_text
  end

  class LabelledContext
    def resolve(controller)
      id = controller.session[:actor_id]
      id && RailsAiAdmin::Context.new(actor: Labelled.new(id), tenant: TestTenant.new(1), security_version: "1")
    end
  end

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def test_grants_are_exactly_what_each_resource_declares
    with_essential_resources(policy: PRESET) do
      grants = RailsAiAdmin::TestKit.field_grants(context: context, resource: ArticleAdmin)
      assert_equal %w[contact id opens_at settings tags title updated_at views website], grants.fetch("read"), "a password is never readable"
      assert_equal %w[contact opens_at password settings tags title views website], grants.fetch("write"), "the key and readonly fields stay closed"
      assert_equal %w[contact title], grants.fetch("search")
      assert_equal %w[opens_at title], grants.fetch("sort")
      assert_equal %w[views], grants.fetch("filter")
      assert_equal %w[popular], RailsAiAdmin::TestKit.named_scope_grants(context: context, resource: ArticleAdmin)
      access = RailsAiAdmin::Authorization::Access.new(context(actor: 2), ArticleAdmin)
      %i[index show create update destroy].each { |action| assert access.authorize!(action, action == :index ? nil : @article), action.to_s }
      assert access.authorize_selection!
      assert access.authorize_export!
      assert access.authorize_import!
      assert access.authorize_audit_log!
      assert access.authorize_history!(@article)
      assert_raises(RailsAiAdmin::AccessDenied, "the assistant is a separate decision") { access.authorize_assistant! }
    end
  end

  def test_a_readonly_resource_and_undeclared_actions_stay_closed
    with_essential_resources(resources: [ "EssentialFixtures::ReadonlyArticleAdmin" ], policy: PRESET) do
      access = RailsAiAdmin::Authorization::Access.new(context, ReadonlyArticleAdmin)
      assert access.authorize!(:show, @article)
      %i[create update destroy].each { |action| assert_raises(RailsAiAdmin::AccessDenied) { access.authorize!(action, @article) } }
      assert_raises(RailsAiAdmin::AccessDenied) { access.authorize!(:publish, @article) }
      assert_equal %w[id title], access.fields(:read).map { |field| field.name.to_s }
    end
  end

  def test_a_subclass_narrows_one_decision_and_keeps_the_rest
    foreign = Article.create!(account_id: 2, title: "Foreign", views: 3)
    with_essential_resources(policy: "FullAccessTest::TenantPolicy") do
      access = RailsAiAdmin::Authorization::Access.new(context(actor: 2), ArticleAdmin)
      assert_equal [ @article.id ], access.relation.pluck(:id)
      assert_raises(RailsAiAdmin::AccessDenied) { access.find!(foreign.id) }
      assert_raises(RailsAiAdmin::AccessDenied) { access.authorize!(:update, @article) }
      assert_includes access.fields(:read).map(&:name), :views
    end
  end

  def test_pages_work_without_any_host_policy_code
    with_essential_resources(policy: PRESET) do
      get "/backoffice/articles"
      assert_response :success
      assert_select "td a.raa-row-title[href='/backoffice/articles/#{@article.id}']", text: "First"
      assert_select "td.raa-row-actions a", text: "Edit"
      assert_select "td.raa-row-actions a", text: "View", count: 0
      assert_select "form.raa-export"
      assert_select "a", text: "Import CSV"
      assert_select "nav a[href='/backoffice/audit']"
      get "/backoffice/articles/#{@article.id}/edit"
      intent = css_select("input[name=intent_ref]").first["value"]
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: { title: "Second", views: "4" } }
      assert_response :see_other
      assert_equal [ "Second", 4 ], @article.reload.values_at(:title, :views)
      get "/backoffice/articles/#{@article.id}"
      assert_select "a", text: "History"
    end
  end

  # Without a title column each row keeps a View link named for its record.
  def test_a_list_without_its_title_column_keeps_a_view_link
    resource = Class.new(RailsAiAdmin::Resource) do
      model "Article"
      key :numbered_articles
      title :title
      fields do
        id :id
        text :title, index: false
        integer :views
      end
    end
    Object.const_set(:NumberedArticleAdmin, resource)
    with_essential_resources(resources: [ "NumberedArticleAdmin" ], policy: PRESET) do
      get "/backoffice/numbered_articles"
      assert_select "a.raa-row-title", count: 0
      assert_select "td.raa-row-actions a[aria-label='View Record ##{@article.id}'][href='/backoffice/numbered_articles/#{@article.id}']", text: "View"
    end
  ensure
    Object.send(:remove_const, :NumberedArticleAdmin)
  end

  def test_the_header_shows_the_actor_and_a_sign_out_button_only_when_configured
    with_essential_resources(policy: PRESET) do
      get "/backoffice/"
      assert_select ".raa-header-meta .raa-actor", count: 0
      assert_select ".raa-header-meta form", count: 0
      # Narrow screens fold the menu behind a button that script reveals.
      assert_select "nav[data-controller=raa-menu] button.raa-menu-toggle[hidden][aria-controls=raa-menu]", text: "Menu"
      assert_select "nav #raa-menu a[aria-current=page]", text: "Overview"
    end
    with_essential_resources(policy: PRESET, context_adapter: "FullAccessTest::LabelledContext", actor_label: :email, sign_out_path: "/session", sign_out_method: :delete) do
      get "/backoffice/"
      assert_select ".raa-header-meta .raa-actor", text: "staff1@example.test"
      assert_select ".raa-header-meta form.raa-sign-out-form[action='/session'][data-turbo=false]" do
        assert_select "input[name=_method][value=delete]"
        assert_select "button.raa-sign-out", text: "Sign out"
      end
    end
    with_essential_resources(policy: PRESET, context_adapter: "FullAccessTest::LabelledContext", actor_label: :secret) do
      get "/backoffice/"
      assert_select ".raa-header-meta .raa-actor", count: 0, message: "only plain text is shown"
    end
  end

  def test_doctor_names_the_preset_and_resource_files_left_unregistered
    Dir.mktmpdir("raa-doctor-", File.expand_path("../../tmp", __dir__)) do |directory|
      FileUtils.mkdir_p(File.join(directory, "app/rails_ai_admin/essential_fixtures"))
      %w[essential_fixtures/tag_admin.rb essential_fixtures/readonly_article_admin.rb essential_fixtures/missing_admin.rb].each do |path|
        File.write(File.join(directory, "app/rails_ai_admin", path), "")
      end
      application = Struct.new(:root, :autoloaders).new(Pathname.new(directory), Rails.application.autoloaders)
      doctor = lambda do |policy|
        with_essential_resources(policy: policy) do |registry|
          config = RailsAiAdmin.configuration
          RailsAiAdmin::Doctor.new(configuration: config, registry: registry, application: application).checks
        end
      end
      checks = doctor.call(PRESET)
      preset = checks.find { |check| check.name == "policy_preset" }
      assert_equal :review, preset.status
      assert_includes preset.message, "Record scope overridden=false"
      assert_includes preset.message, "assistant grant overridden=false"
      assert_equal [ "unregistered:EssentialFixtures::ReadonlyArticleAdmin" ], checks.map(&:name).grep(/\Aunregistered:/), "registered and unknown names are skipped"
      assert_includes doctor.call("FullAccessTest::TenantPolicy").find { |check| check.name == "policy_preset" }.message, "Record scope overridden=true"
      refute_includes doctor.call("EssentialFixtures::Policy").map(&:name), "policy_preset"
    end
  end

  def test_header_settings_are_validated_at_boot
    valid = { actor_label: "email_address", sign_out_path: "/users/sign_out", sign_out_method: :get }
    config = RailsAiAdmin::Configuration.new
    valid.each { |name, value| config.public_send("#{name}=", value) }
    config.finalize!
    assert_equal :email_address, config.actor_label
    { actor_label: "email address", sign_out_path: "https://example.test/out", sign_out_method: :put }.each do |name, value|
      config = RailsAiAdmin::Configuration.new
      config.public_send("#{name}=", value)
      assert_raises(RailsAiAdmin::ConfigurationError, name.to_s) { config.finalize! }
    end
  end
end
