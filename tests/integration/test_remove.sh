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
fixture_add_module "demo/just-aws"    "aws.just"    "v0.1.0" "y"

cd "$PROJ"
just plug init >/dev/null
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
just plug install github.com/demo/just-aws@v0.1.0 >/dev/null

just plug remove docker
assert_file_missing "$PROJ/just-plug/docker.just" "docker file removed"

deps="$(cat just-plug.deps)"
case "$deps" in
    *docker*) ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "FAIL: docker still in deps" ;;
    *) ASSERT_OK=$((ASSERT_OK + 1)) ;;
esac

lock="$(cat just-plug.lock)"
case "$lock" in
    *docker*) ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "FAIL: docker still in lock" ;;
    *) ASSERT_OK=$((ASSERT_OK + 1)) ;;
esac

mods="$(cat just-plug/modules.just)"
case "$mods" in
    *docker*) ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "FAIL: docker still in modules.just" ;;
    *) ASSERT_OK=$((ASSERT_OK + 1)) ;;
esac

# aws still present.
assert_file_exists "$PROJ/just-plug/aws.just" "aws untouched"

# Removing nonexistent module: no error, notice on stderr.
just plug remove nonexistent 2>/dev/null
ASSERT_OK=$((ASSERT_OK + 1))

assert_exit
