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
    @echo hi from url-form
'
fixture_add_module "demo/just-widget" "widget.just" "v1.0.0" "$CONTENT"

# Build a file:// URL pointing at the fixture bare repo.
URL="file://${_FIXTURE_GIT_ROOT}/demo/just-widget"

cd "$PROJ"
just plug init >/dev/null

# Install via the URL form pinned to a tag — exercises the git-fetch path.
just plug install "${URL}@v1.0.0"

assert_file_exists "$PROJ/just-plug/widget.just" "url-form install creates module file"
if diff -q <(printf '%s' "$CONTENT") just-plug/widget.just >/dev/null 2>&1; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: url-form module content mismatch"
fi

deps="$(cat just-plug.deps)"
assert_contains "$deps" "widget $URL v1.0.0" "deps records the URL form as typed"

lock="$(cat just-plug.lock)"
assert_contains "$lock" "widget $URL v1.0.0" "lock records the URL form"

mods="$(cat just-plug/modules.just)"
assert_contains "$mods" 'mod? widget "widget.just"' "modules.just regenerated"

# Install with explicit .git suffix — must normalize to the same source.
fixture_add_module "demo/just-gadget" "gadget.just" "v0.1.0" 'go:
    @echo go
'
GADGET_URL="file://${_FIXTURE_GIT_ROOT}/demo/just-gadget"
just plug install "${GADGET_URL}.git@v0.1.0"
deps="$(cat just-plug.deps)"
assert_contains "$deps" "gadget $GADGET_URL v0.1.0" ".git suffix stripped on store"

# Default ref (no @ref) installs from main.
fixture_add_module "demo/just-mainline" "mainline.just" "v0.0.1" 'hi:
    @echo main
'
MAIN_URL="file://${_FIXTURE_GIT_ROOT}/demo/just-mainline"
just plug install "$MAIN_URL"
deps_main="$(awk '$1 == "mainline"' just-plug.deps)"
assert_contains "$deps_main" "main" "default ref is main for URL form"

assert_exit
