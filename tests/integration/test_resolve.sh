#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

# Project dir for invoking plug.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/justfile" <<EOF
mod? plug "$PLUG"
EOF

fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" 'show:
    @echo hi
'

# Resolve a tag — should return a 40-char SHA.
SHA="$(cd "$PROJ" && just plug _resolve-ref demo/just-docker v1.0.0)"
assert_eq 40 "${#SHA}" "tag resolves to 40-char SHA"

# Resolve the default branch.
MAIN_SHA="$(cd "$PROJ" && just plug _resolve-ref demo/just-docker main)"
assert_eq 40 "${#MAIN_SHA}" "branch resolves to 40-char SHA"

# Pass-through for SHAs.
OUT="$(cd "$PROJ" && just plug _resolve-ref demo/just-docker "$SHA")"
assert_eq "$SHA" "$OUT" "SHA passes through unchanged"

# Short SHA-like (10 hex chars) also passes through.
OUT="$(cd "$PROJ" && just plug _resolve-ref demo/just-docker abc1234567)"
assert_eq "abc1234567" "$OUT" "short SHA passes through"

# Nonexistent ref fails.
if (cd "$PROJ" && just plug _resolve-ref demo/just-docker no-such-ref) 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: missing ref should error"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
