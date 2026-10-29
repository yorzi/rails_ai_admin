#!/usr/bin/env bash
# Preview the working tree at http://127.0.0.1:4000 with live reload. Ctrl-C stops it.
#   docs/bin/serve.sh        PORT=4002 docs/bin/serve.sh
set -euo pipefail

unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

docs="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$docs"
exec env BUNDLE_GEMFILE="$docs/Gemfile" bundle exec jekyll serve \
  --host 127.0.0.1 --port "${PORT:-4000}" \
  --livereload --livereload-port "${LIVERELOAD_PORT:-35729}"
