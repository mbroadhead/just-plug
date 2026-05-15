#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/justfile" <<EOF
mod? plug "$PLUG"
EOF
cd "$TMP"

# Fresh init.
out="$(just plug init)"
assert_file_exists "$TMP/just-plug" "just-plug dir created"
assert_file_exists "$TMP/just-plug.deps" "deps file created"
assert_eq "" "$(cat just-plug.deps)" "deps file is empty"
assert_contains "$out" 'mod? plug "just-plug/plug.just"' "instructions include mod line"
assert_contains "$out" 'import? "just-plug/modules.just"' "instructions include import line"

# Pre-populated deps must not be clobbered.
echo "foo github.com/x/foo main" > "$TMP/just-plug.deps"
just plug init >/dev/null
assert_eq "foo github.com/x/foo main" "$(cat just-plug.deps)" "init does not clobber existing deps"

assert_exit
