#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

# Fixture serves the real plug.just at tag v0.99.0.
PLUG_CONTENT="$(cat "$PLUG")"
fixture_add_module "mbroadhead/just-plug" "plug.just" "v0.99.0" "$PLUG_CONTENT"

# Set up a project whose installed plug.just is the real one plus a marker
# line. self-update should replace the file and lose the marker.
PROJ="$TMP/proj"
mkdir -p "$PROJ/just-plug"
INSTALLED_CONTENT="$PLUG_CONTENT
# fixture-marker-line"
printf '%s' "$INSTALLED_CONTENT" > "$PROJ/just-plug/plug.just"
cat > "$PROJ/justfile" <<EOF
mod? plug "just-plug/plug.just"
EOF

URL="file://${_FIXTURE_GIT_ROOT}/mbroadhead/just-plug"

cd "$PROJ"

# First update — file should change.
out="$(just plug self-update "${URL}@v0.99.0")"
assert_contains "$out" "updated just-plug" "first run reports update"
if grep -qF "fixture-marker-line" just-plug/plug.just; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: marker line still present after update"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Second update — idempotent.
out="$(just plug self-update "${URL}@v0.99.0")"
assert_contains "$out" "up to date" "second run reports up to date"

assert_exit
