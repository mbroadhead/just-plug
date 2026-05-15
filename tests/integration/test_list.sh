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
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "x"

cd "$PROJ"
just plug init >/dev/null

# Empty list.
out="$(just plug list)"
assert_contains "$out" "no modules installed" "empty list message"

just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
out="$(just plug list)"
assert_contains "$out" "docker" "list shows docker"
assert_contains "$out" "v1.0.0" "list shows ref"
assert_contains "$out" "github.com/demo/just-docker" "list shows source"

assert_exit
