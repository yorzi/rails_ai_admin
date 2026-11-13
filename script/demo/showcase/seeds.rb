# Showcase content for bin/demo --showcase.
a = Account.find_by!(name: "Tenant A")
tags = %w[Guide Release Security Rails Ruby].map { |name| Tag.create!(account: a, name: name) }
12.times do |i|
  article = Article.create!(account: a, title: "Article #{i + 1}: #{[ "Getting started", "Upgrading", "Policies", "Uploads", "Search" ][i % 5]}",
    views: i * 7, contact: "editor#{i}@example.test", website: "https://example.test/articles/#{i + 1}",
    opens_at: format("%02d:%02d", 8 + (i % 8), (i * 15) % 60), settings: { "featured" => i.even?, "slots" => [ i, i + 1 ] },
    body: "<div>Body of article #{i + 1} with <strong>bold</strong> and <em>italic</em> text.</div>")
  article.tags = tags.sample(2, random: Random.new(i))
  Summary.create!(account: a, article: article, text: "Summary of article #{i + 1}") if i.even?
end
