# Showcase content for bin/demo: articles with covers, galleries, tags,
# summaries and dates spread over the last month for the overview trend.
require "zlib"

# A solid-colour PNG, so the demo needs no image files.
def showcase_png(red, green, blue, width: 96, height: 64)
  chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
  rows = Array.new(height) { "\x00".b + ([ red, green, blue ].pack("C3") * width) }.join
  "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")) + chunk.call("IDAT", Zlib::Deflate.deflate(rows)) + chunk.call("IEND", "")
end

a = Account.find_by!(name: "Tenant A")
[ 12, 8 ].each { |points| Customer.create!(account: a, name: "North Pier", active: true, points: points) }
tags = %w[Guide Release Security Rails Ruby].map { |name| Tag.create!(account: a, name: name) }
palette = [ [ 21, 94, 117 ], [ 173, 37, 48 ], [ 217, 119, 6 ], [ 22, 101, 52 ], [ 91, 33, 182 ] ]
topics = [ "Getting started", "Upgrading", "Policies", "Uploads", "Search" ]
days_ago = [ 0, 1, 1, 2, 4, 4, 4, 6, 8, 10, 10, 13, 15, 18, 19, 19, 23, 27 ]
days_ago.each_with_index do |days, i|
  written = days.days.ago - (1 + i % 8).hours
  article = Article.create!(account: a, title: "Article #{i + 1}: #{topics[i % 5]}",
    views: (i * 23) % 120, contact: "editor#{i}@example.test", website: "https://example.test/articles/#{i + 1}",
    opens_at: format("%02d:%02d", 8 + (i % 8), (i * 15) % 60), settings: { "featured" => i.even?, "slots" => [ i, i + 1 ] },
    body: "<div>Body of article #{i + 1} with <strong>bold</strong> and <em>italic</em> text.</div>",
    created_at: written, updated_at: written)
  article.tags = tags.sample(2, random: Random.new(i))
  color = palette[i % palette.size]
  article.cover.attach(io: StringIO.new(showcase_png(*color)), filename: "cover-#{i + 1}.png", content_type: "image/png") if i < 10
  if i < 4
    3.times do |n|
      shade = color.map { |value| [ value + 40 * n, 255 ].min }
      article.gallery.attach(io: StringIO.new(showcase_png(*shade, width: 64, height: 64)), filename: "photo-#{i + 1}-#{n + 1}.png", content_type: "image/png")
    end
  end
  Summary.create!(account: a, article: article, text: "Summary of article #{i + 1}") if i.even?
end

Customer.create!(account: a, name: "New member", points: 0, active: true)
admin = User.find_by!(email: "admin@example.test")
operator = RailsAiAdmin::Context.new(actor: admin, tenant: a, security_version: admin.security_version)
report = RailsAiAdmin::Presentation::SavedQueries.save!(context: operator, resource: OrderAdmin, name: "Orders by review state",
  ast: { "kind" => "metric", "function" => "count", "group_by" => "state", "scope" => "all" }, shared: true, pinned: true)
RailsAiAdmin::Recipes.configure!(owner: operator, principal: operator, slug: "first_award", resource: :customers,
  name: "First customer award", instructions: "Propose ten points for each active customer awaiting a first award. Review the fixed selection together.",
  plan: { template: "order_monitor", scope: "first_award", operation: "reviewed_bulk_award", input: { amount: 10 } }, enabled: true)
RailsAiAdmin::Recipes.configure!(owner: operator, principal: operator, slug: "daily_order_brief", resource: :orders,
  name: "Daily order brief", instructions: "Open the order report for the morning review.",
  trigger: "schedule", cron: "0 9 * * 1-5", time_zone: "Asia/Shanghai",
  plan: { template: "daily_business_brief", report_id: report.id }, enabled: true)
RailsAiAdmin::Recipes.configure!(owner: operator, principal: operator, slug: "check_customer_duplicates", resource: :customers,
  name: "Customer duplicate check", instructions: "Check active customers with the same name.",
  trigger: "event", event: "customer.review_requested",
  plan: { template: "duplicate_detector", rule: "duplicate_active_customers" }, enabled: true)
run = RailsAiAdmin::Recipes.emit("customer.review_requested", tenant_ref: operator.tenant_ref, dedup_key: "seed-review").sole
RailsAiAdmin::Recipes::Execution.call(run.id)
