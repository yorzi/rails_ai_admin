#!/usr/bin/env bash
# Build the docs into docs/_site.
# Once the latest release tag has docs, that release is built at /, the working
# tree at /next/, and the newest tag of each older major version that has docs
# at /vN/. Until then, the working tree is built at /.
#   docs/bin/build.sh        BASE=/repo docs/bin/build.sh        SITE=/tmp/out docs/bin/build.sh
# BASE is the site's base path. It defaults to baseurl in _config.yml; the
# workflow sets it from GitHub Pages, and an empty BASE means the site is at the
# root of its domain.
set -euo pipefail

unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_BIN BUNDLE_APP_CONFIG

docs="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(git -C "$docs" rev-parse --show-toplevel)"
rel="${docs#"$repo"/}"
site="${SITE:-$docs/_site}"
gemfile="$docs/Gemfile"
read_config() { ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0))[ARGV.fetch(1)].to_s.chomp("/")' "$docs/_config.yml" "$1"; }
origin="$(read_config url)"
BASE="${BASE-$(read_config baseurl)}"
BASE="${BASE%/}"

# A tag has docs when its tree holds this site's _config.yml on the same theme.
has_docs() { git -C "$repo" show "$1:$rel/_config.yml" 2>/dev/null | grep -q 'jekyll-vitepress-theme'; }
major() { local version="${1#v}"; echo "${version%%.*}"; }

tags="$(git -C "$repo" tag --list --sort=-v:refname | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)"
latest="$(printf '%s\n' "$tags" | head -n 1)"
release=""
if [[ -n "$latest" ]] && has_docs "$latest"; then
  release="$latest"
fi

build_api() {
  local output="$1" source_root="$2" prefix="$3"
  if [[ -x "$docs/bin/build-api.sh" ]]; then
    SITE_URL="$origin$prefix" ROOT_URL="$origin$BASE" "$docs/bin/build-api.sh" "$output/api" "$source_root"
  fi
}

if [[ -z "$release" ]]; then
  ( cd "$docs" && BUNDLE_GEMFILE="$gemfile" bundle exec jekyll build --baseurl "$BASE" -d "$site" --quiet )
  build_api "$site" "$repo" "$BASE"
  echo "Built the working tree at ${BASE:-/}. No release has docs yet, so there is no /next/."
  exit 0
fi

archives=()
top="$(major "$release")"
seen=" "
while read -r tag; do
  [[ -n "$tag" ]] || continue
  number="$(major "$tag")"
  if (( number >= top )) || [[ "$seen" == *" $number "* ]]; then continue; fi
  seen="$seen$number "
  if has_docs "$tag"; then archives+=("$tag"); fi
done <<< "$tags"

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

extract() {
  local tag="$1" target="$2" path
  local paths=("$rel")
  for path in lib .rdoc_options README.md; do
    if git -C "$repo" cat-file -e "$tag:$path" 2>/dev/null; then paths+=("$path"); fi
  done
  mkdir -p "$target"
  git -C "$repo" archive "$tag" -- "${paths[@]}" | tar -x -C "$target"
  if [[ ! -f "$target/.rdoc_options" && -f "$repo/.rdoc_options" ]]; then
    cp "$repo/.rdoc_options" "$target/.rdoc_options"
  fi
}

prepare() {
  local source="$1" channel="$2"
  mkdir -p "$source/_data" "$source/_plugins"
  cp "$docs/bin/versions.yml" "$source/_data/versions.yml"
  cp "$docs/_plugins/versioned_docs.rb" "$source/_plugins/"
  ruby "$docs/bin/prepare_versions.rb" "$source/_data/versions.yml" "$channel" "$BASE" "$release" \
    ${archives[@]+"${archives[@]}"}
}

build() {
  local source="$1" output="$2" prefix="$3" source_root="$4"
  ( cd "$source" && BUNDLE_GEMFILE="$gemfile" bundle exec jekyll build --baseurl "$prefix" -d "$output" --quiet )
  build_api "$output" "$source_root" "$prefix"
}

extract "$release" "$workspace/stable"
prepare "$workspace/stable/$rel" stable
build "$workspace/stable/$rel" "$workspace/stable-out" "$BASE" "$workspace/stable"

mkdir -p "$workspace/next"
rsync -a --exclude=_site --exclude=vendor --exclude=.jekyll-cache --exclude=.bundle "$docs/" "$workspace/next/"
prepare "$workspace/next" next
build "$workspace/next" "$workspace/next-out" "$BASE/next" "$repo"

channels=(next)
for tag in ${archives[@]+"${archives[@]}"}; do
  channel="v$(major "$tag")"
  extract "$tag" "$workspace/$channel"
  prepare "$workspace/$channel/$rel" "$channel"
  build "$workspace/$channel/$rel" "$workspace/$channel-out" "$BASE/$channel" "$workspace/$channel"
  channels+=("$channel")
done

rm -rf "$site"
mkdir -p "$site"
cp -a "$workspace/stable-out/." "$site/"
for channel in "${channels[@]}"; do
  mkdir -p "$site/$channel"
  cp -a "$workspace/$channel-out/." "$site/$channel/"
done
ruby "$docs/bin/link_versions.rb" "$site" "$origin" "$BASE" "${channels[@]}"

summary="Built $release at ${BASE:-/} and the working tree at $BASE/next/"
for tag in ${archives[@]+"${archives[@]}"}; do
  summary="$summary, $tag at $BASE/v$(major "$tag")/"
done
echo "$summary."
