#!/usr/bin/env bash
# Verifies JUST_PLUG_DIR relocates artifacts to a subdirectory.
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

fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" 'show:
    @echo hi
'

cd "$PROJ"
export JUST_PLUG_DIR="tools"

# init places artifacts under tools/, not at project root.
init_out="$(just plug init)"
assert_contains "$init_out" "artifacts installed in" "init notes resolved root when JUST_PLUG_DIR set"
assert_contains "$init_out" "/tools"                  "init note mentions the relocated dir"
assert_file_exists "$PROJ/tools/just-plug"      "init created tools/just-plug dir"
assert_file_exists "$PROJ/tools/just-plug.deps" "init created tools/just-plug.deps"
assert_file_missing "$PROJ/just-plug"           "no just-plug dir at project root"
assert_file_missing "$PROJ/just-plug.deps"      "no deps file at project root"

# install routes through JUST_PLUG_DIR.
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
assert_file_exists "$PROJ/tools/just-plug/docker.just"   "module installed under tools/"
assert_file_exists "$PROJ/tools/just-plug.lock"          "lock written under tools/"
assert_file_exists "$PROJ/tools/just-plug/modules.just"  "modules.just written under tools/"
assert_file_missing "$PROJ/just-plug/docker.just"        "no module at project root"

# list / verify read relocated state.
out="$(just plug list)"
assert_contains "$out" "docker" "list reads relocated lock"

just plug verify >/dev/null
ASSERT_OK=$((ASSERT_OK + 1))

# remove deletes from relocated location.
just plug remove docker >/dev/null
assert_file_missing "$PROJ/tools/just-plug/docker.just" "remove deletes from relocated dir"

# Absolute path also works.
ABS="$TMP/abs"
PROJ2="$TMP/proj2"
mkdir -p "$PROJ2"
cat > "$PROJ2/justfile" <<EOF
mod? plug "$PLUG"
EOF
cd "$PROJ2"
export JUST_PLUG_DIR="$ABS"
just plug init >/dev/null
assert_file_exists "$ABS/just-plug"      "absolute-path init creates dir"
assert_file_exists "$ABS/just-plug.deps" "absolute-path init creates deps"
assert_file_missing "$PROJ2/just-plug"   "absolute path does not write under proj2"

assert_exit
