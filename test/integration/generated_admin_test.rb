# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"
require "support/attachments"
require "generators/rails_ai_admin/resource/resource_generator"
require "tmpdir"

module Generated
  class Note < ActiveRecord::Base
    self.table_name = "payments"
  end
end

# The resource generator's output, registered as written and served under the
# full-access preset: no hand-written resource or policy code.
class GeneratedAdminTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  MODELS = %w[Article Summary Tag Tagging Document Generated::Note].freeze
  CONSTANTS = %w[ArticleAdmin SummaryAdmin TagAdmin TaggingAdmin DocumentAdmin Generated::NoteAdmin].freeze
  INITIALIZER = <<~RUBY
    RailsAiAdmin.configure do |config|
      config.context_adapter = "AdminContext"
      # config.resources = ["Commented"]
      config.resources = []
    end
  RUBY

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def generate(directory, names, flags = [])
    generator = RailsAiAdmin::Generators::ResourceGenerator.new(names, flags, destination_root: directory)
    yield generator if block_given?
    capture_io { generator.invoke_all }.first
  end

  def with_initializer
    Dir.mktmpdir("raa-generated-", File.expand_path("../../tmp", __dir__)) do |directory|
      FileUtils.mkdir_p(File.join(directory, "config/initializers"))
      File.write(File.join(directory, "config/initializers/rails_ai_admin.rb"), INITIALIZER)
      yield directory
    end
  end

  def read(directory, path) = File.read(File.join(directory, path))

  def test_generated_resources_register_and_serve_pages_as_written
    with_initializer do |directory|
      output = generate(directory, MODELS)
      article = read(directory, "app/rails_ai_admin/article_admin.rb")
      assert_includes article, "    text :title, nullable: false, searchable: :contains, sortable: true\n"
      assert_includes article, "    url :website\n"
      assert_includes article, "    columns :id, :title, :views, :contact, :website, :opens_at, :created_at\n"
      assert_includes article, "  has_one :summary\n  has_many :taggings\nend\n"
      refute_match(/password_digest|account/, article)
      # has_secure_password is offered as a comment, never enabled.
      assert_includes article, "    # password :password\n"
      refute_match(/^\s+password :/, article)
      assert_includes read(directory, "app/rails_ai_admin/summary_admin.rb"), "    belongs_to :article, nullable: false, filterable: true\n"
      assert_includes read(directory, "app/rails_ai_admin/tagging_admin.rb"),
        "  title :id\n  # Tagging has no updated_at or lock_version column, which saving needs to\n  # notice an edit made in between. Add timestamps, then remove this line.\n  readonly\n"
      refute_match(/^  readonly$/, article)
      assert_includes output, "Tagging has no updated_at or lock_version column, so it is readonly here."
      document = read(directory, "app/rails_ai_admin/document_admin.rb")
      [ "file :cover", "file :contract", "files :photos", "rich_text :body" ].each { |line| assert_includes document, "    #{line}\n" }
      note = read(directory, "app/rails_ai_admin/generated/note_admin.rb")
      assert_includes note, "class Generated::NoteAdmin < RailsAiAdmin::Resource\n  model \"Generated::Note\"\n  key :generated_notes\n"
      assert_includes read(directory, "config/initializers/rails_ai_admin.rb"),
        "  # config.resources = [\"Commented\"]\n  config.resources = %w[\n#{CONSTANTS.map { |name| "    #{name}\n" }.join}  ]\nend\n"
      assert_includes output, "Registered in config/initializers/rails_ai_admin.rb."
      assert_includes output, "use RailsAiAdmin::Authorization::FullAccessAdapter"

      MODELS.each { |name| Object.class_eval(read(directory, "app/rails_ai_admin/#{name.underscore}_admin.rb")) }
      begin
        Summary.create!(account_id: 1, article: @article, text: "Short")
        with_essential_resources(resources: CONSTANTS, policy: "RailsAiAdmin::Authorization::FullAccessAdapter") do
          get "/backoffice/articles"
          assert_response :success
          assert_select "th[aria-sort=descending] a", text: "Created at"
          assert_select "td a.raa-row-title", text: "First"
          assert_select "p.raa-count", text: "1 matching record"
          assert_select "form.raa-search"
          get "/backoffice/articles/#{@article.id}"
          assert_response :success
          assert_select "section.raa-association h2", text: "Summary"
          assert_select "section.raa-association a", text: "Short"
          get "/backoffice/articles/#{@article.id}/edit"
          assert_response :success
          assert_select "input[name='record[title]']"
          assert_select "input[name='record[created_at]']", count: 0
          %w[summaries tags taggings documents generated_notes].each do |key|
            get "/backoffice/#{key}"
            assert_response :success, "#{key}: #{css_select('main').text.squish.first(300)}"
          end
          # Summaries have no version column, so their resource is readonly.
          get "/backoffice/summaries"
          assert_select "a", text: "New summary", count: 0
          get "/backoffice/documents/new"
          assert_response :success
          assert_select "input[type=file][name='record[cover]']"
        end
      ensure
        CONSTANTS.each { |name| name.deconstantize.presence&.constantize&.send(:remove_const, name.demodulize) || Object.send(:remove_const, name) }
      end
    end
  end

  def test_colliding_generated_keys_fail_before_writing
    with_initializer do |directory|
      assert_raises(Rails::Generators::Error) { generate(directory, %w[Billing::Invoice BillingInvoice]) }
      assert_empty Dir[File.join(directory, "app/rails_ai_admin/**/*.rb")]
      assert_equal INITIALIZER, read(directory, "config/initializers/rails_ai_admin.rb")
    end
  end

  def test_registration_keeps_existing_entries_and_is_skippable
    with_initializer do |directory|
      path = File.join(directory, "config/initializers/rails_ai_admin.rb")
      File.write(path, INITIALIZER.sub("config.resources = []", "config.resources = [ \"CustomerAdmin\", 'OrderAdmin' ]"))
      generate(directory, [ "Tag" ])
      assert_includes File.read(path), "  config.resources = %w[CustomerAdmin OrderAdmin TagAdmin]\n"
      generate(directory, [ "Tag" ], [ "--force" ])
      assert_equal 1, File.read(path).scan("TagAdmin").size, "a second run changes nothing"
      output = generate(directory, [ "Summary" ], [ "--no-register" ])
      refute_includes File.read(path), "SummaryAdmin"
      assert_includes output, "Add \"SummaryAdmin\" to config.resources"
      # A list the generator cannot read as plain names is left alone.
      File.write(path, INITIALIZER.sub("config.resources = []", "config.resources = [ADMIN]"))
      output = generate(directory, [ "Article" ])
      assert_includes File.read(path), "config.resources = [ADMIN]"
      assert_includes output, "Add \"ArticleAdmin\" to config.resources"
    end
  end

  def test_all_fills_gaps_for_models_under_the_source_root_only
    with_initializer do |directory|
      root = "#{File.expand_path('../support', __dir__)}/"
      FileUtils.mkdir_p(File.join(directory, "app/rails_ai_admin"))
      File.write(File.join(directory, "app/rails_ai_admin/tag_admin.rb"), "# reviewed by hand\n")
      output = generate(directory, [ "Generated::Note" ], [ "--all" ]) { |generator| generator.define_singleton_method(:model_source_root) { root } }
      written = Dir[File.join(directory, "app/rails_ai_admin/**/*_admin.rb")].map { |path| path.delete_prefix("#{directory}/app/rails_ai_admin/") }.sort
      assert_includes written, "generated/note_admin.rb", "a named model outside the root is still written"
      %w[article_admin.rb summary_admin.rb tagging_admin.rb document_admin.rb invoice_admin.rb].each { |name| assert_includes written, name }
      refute_includes written, "schema_suggestion_record_admin.rb", "models defined elsewhere are not discovered"
      assert_equal "# reviewed by hand\n", read(directory, "app/rails_ai_admin/tag_admin.rb")
      refute_includes output, "TagAdmin"
      # A reference to a model without a resource stays a comment.
      assert_includes read(directory, "app/rails_ai_admin/tagging_admin.rb"), "    # belongs_to :tag, nullable: false\n"
      assert_includes read(directory, "app/rails_ai_admin/tagging_admin.rb"), "    belongs_to :article, nullable: false, filterable: true\n"
      again = generate(directory, [], [ "--all" ]) { |generator| generator.define_singleton_method(:model_source_root) { root } }
      assert_includes again, "Every model in app/models already has a resource."
    end
  end
end
