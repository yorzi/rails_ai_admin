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
tags = %w[Guide Release Security Rails Ruby].map { |name| Tag.create!(account: a, name: name) }
palette = [ [ 21, 94, 117 ], [ 173, 37, 48 ], [ 217, 119, 6 ], [ 22, 101, 52 ], [ 91, 33, 182 ] ]
topics = [ "Getting started", "Upgrading", "Policies", "Uploads", "Search" ]
18.times do |i|
  written = (i * 37 % 29).days.ago - (1 + i % 8).hours
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
