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

CONTENT='show:
    @echo hi
'
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "$CONTENT"

SHA="$(cd "$PROJ" && just plug _resolve-ref demo/just-docker v1.0.0)"
DEST="$TMP/out.just"

HASH="$(cd "$PROJ" && just plug _fetch demo/just-docker "$SHA" docker.just "$DEST")"
assert_file_exists "$DEST" "destination file written"
# Compare file bytes directly (avoids command-substitution trailing-newline stripping).
EXPECTED_FILE="$TMP/expected.just"
printf '%s' "$CONTENT" > "$EXPECTED_FILE"
if diff -q "$EXPECTED_FILE" "$DEST" >/dev/null 2>&1; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: content matches"
    diff "$EXPECTED_FILE" "$DEST" || true
fi
assert_eq 64 "${#HASH}" "sha256 is 64 hex chars"

# Verify the hash matches what shasum produces.
EXPECTED_HASH="$(printf '%s' "$CONTENT" | shasum -a 256 | awk '{print $1}')"
assert_eq "$EXPECTED_HASH" "$HASH" "sha256 is correct"

# Fetch failure: nonexistent SHA. Pre-existing dest must be untouched.
echo "PRESERVED" > "$DEST"
if (cd "$PROJ" && just plug _fetch demo/just-docker 0000000000000000000000000000000000000000 docker.just "$DEST") 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: fetch from nonexistent SHA should error"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi
assert_eq "PRESERVED" "$(cat "$DEST")" "destination untouched on failure"

assert_exit
