#!/usr/bin/env bash
# Build the RDoc API reference, with a Markdown copy of every class page and
# the guides' search and social metadata, into <output-dir>.
#   docs/bin/build-api.sh <output-dir> [source-root]
# bin/build.sh sets SITE_URL to the build's address (such as
# https://example.com/next) and ROOT_URL to the production site's.
set -euo pipefail

out="${1:?usage: build-api.sh <output-dir> [source-root]}"
docs="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="${2:-$(git -C "$docs" rev-parse --show-toplevel)}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

( cd "$source_root" && ruby -rrdoc/rdoc -e 'RDoc::RDoc.new.document(ARGV)' -- --output "$out" --quiet lib )
ruby "$docs/bin/export-api-markdown.rb" "$out" "$source_root" "Rails AI Admin"

main="RailsAiAdmin"
if [[ -n "$main" && -f "$out/$main.html" ]]; then
  # Both pages sit at the same depth, so the module page's relative links work at /api/.
  cp "$out/$main.html" "$out/index.html"
fi

ruby "$docs/bin/postprocess_api_seo.rb" "$out" "$docs/_config.yml" "$main.html"
