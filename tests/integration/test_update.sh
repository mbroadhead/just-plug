#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/justfile" <<EOF
mod? plug "$PLUG"
EOF

# Initial install at v1.0.0.
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "old"

cd "$PROJ"
just plug init >/dev/null
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
old_sha="$(awk '$1=="docker" {print $4}' just-plug.lock)"

# Adding a new commit to the v1.0.0 tag in the fixture means: re-tag.
# Simulate by force-moving the tag to a new commit with new content.
WORK="$TMP/fix/work/demo/just-docker"
(cd "$WORK"
 printf 'new' > docker.just
 git -c user.email=t@t -c user.name=t commit -q -am "update"
 git tag -f v1.0.0
 # Push the new commit and tag to the bare repo so ls-remote sees it.
 git push -f "$TMP/fix/git/demo/just-docker" main >/dev/null 2>&1 || true
 git push -f --tags "$TMP/fix/git/demo/just-docker" >/dev/null 2>&1
)
new_sha="$(git -C "$TMP/fix/git/demo/just-docker" rev-parse v1.0.0)"
# Mirror new content for raw HTTP.
mkdir -p "$TMP/fix/raw/demo/just-docker/$new_sha"
printf 'new' > "$TMP/fix/raw/demo/just-docker/$new_sha/docker.just"

# Pin to v1.0.0 still — update should pull the moved tag.
just plug update docker
updated_sha="$(awk '$1=="docker" {print $4}' just-plug.lock)"
assert_eq "$new_sha" "$updated_sha" "lock SHA updated to new tag target"

# File content reflects new commit.
assert_eq "new" "$(cat just-plug/docker.just)" "file content updated"

# No-op update: running again with no remote change leaves SHA unchanged.
sha_before="$updated_sha"
just plug update docker
sha_after="$(awk '$1=="docker" {print $4}' just-plug.lock)"
assert_eq "$sha_before" "$sha_after" "no-op update is stable"

assert_exit
