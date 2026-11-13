# frozen_string_literal: true

require "test_helper"
require "support/application"

# Framework I18n gate: every page, helper and controller string comes from
# config/locales, and a host locale replaces it.
class I18nTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  ROOT = File.expand_path("../..", __dir__)
  LOCALE = YAML.load_file(File.join(ROOT, "config/locales/en.yml")).fetch("en")

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def test_every_literal_framework_key_has_english_text
    sources = Dir[File.join(ROOT, "{app,lib}/**/*.{rb,erb}")]
    keys = sources.flat_map { |path| File.read(path).scan(/\bt\("(rails_ai_admin\.[a-z0-9_.]+)"/).flatten }.uniq
    assert_operator keys.size, :>=, 150
    missing = keys.reject do |key|
      value = LOCALE.dig(*key.split("."))
      value.is_a?(String) || value.is_a?(Hash)
    end
    assert_empty missing, "add these keys to config/locales/en.yml"
  end

  def test_a_host_locale_replaces_framework_text
    previous_locales = I18n.available_locales
    I18n.available_locales = previous_locales | [ :de ]
    # A complete host locale: the English tree with a few strings replaced.
    I18n.backend.store_translations(:de, LOCALE)
    I18n.backend.store_translations(:de, rails_ai_admin: { dashboard: { title: "Übersicht" }, layout: { skip: "Zum Inhalt" },
      statuses: { not_found: { title: "Nicht gefunden" } }, script: { leave_form: "Formular verlassen?" } })
    I18n.with_locale(:de) do
      get "/backoffice"
      assert_response :success
      assert_select "html[lang=de]"
      assert_select "h1", text: "Übersicht"
      assert_select "a.raa-skip", text: "Zum Inhalt"
      assert_equal "Formular verlassen?", JSON.parse(css_select("body").first["data-raa-messages"])["leave_form"]
      get "/backoffice/customers/#{@other.id}"
      assert_response :not_found
      assert_select "h1", text: "Nicht gefunden"
    end
  ensure
    I18n.available_locales = previous_locales
    I18n.reload!
  end
end
