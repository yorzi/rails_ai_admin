# frozen_string_literal: true

# Loaded only by the copied hosts' override acceptance pass. Persist identifiers,
# never locals, record values, HTML, tokens or notification payloads.
require "set"
require "rails_ai_admin/templates/catalog"

if ENV["RAA_OVERRIDE_ACCEPTANCE"] == "1"
  catalog = RailsAiAdmin::Templates::Catalog.new
  identifiers = catalog.entries.to_h { |entry| [ Rails.root.join("app/views", entry.path).to_s, entry.key ] }
  rendered = Set.new
  ActiveSupport::Notifications.subscribe(/\Arender_(?:template|partial|layout)\.action_view\z/) do |*args|
    key = identifiers[args.last[:identifier]]
    rendered << key if key
  end
  Minitest.after_run { Rails.root.join("tmp/admin_override_rendered.json").write(JSON.generate(rendered.to_a.sort)) }
end
