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
fixture_add_module "demo/just-aws"    "aws.just"    "v0.1.0" "deploy:
    @echo aws
"
fixture_add_module "rival/docker"     "docker.just" "v1.0.0" "rival:
    @echo rival
"

cd "$PROJ"
just plug init >/dev/null

# Install one module pinned to a tag.
just plug install github.com/demo/just-docker@v1.0.0

assert_file_exists "$PROJ/just-plug/docker.just" "module file installed"
# Content-equality: use diff because $() strips trailing newlines.
if diff -q <(printf '%s' "$CONTENT") just-plug/docker.just >/dev/null 2>&1; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: module content mismatch"
fi

deps="$(cat just-plug.deps)"
assert_contains "$deps" "docker github.com/demo/just-docker v1.0.0" "deps updated"

lock="$(cat just-plug.lock)"
assert_contains "$lock" "docker github.com/demo/just-docker v1.0.0" "lock updated"

mods="$(cat just-plug/modules.just)"
assert_contains "$mods" 'mod? docker "docker.just"' "modules.just regenerated"

# Install a second, different module.
just plug install github.com/demo/just-aws@v0.1.0
assert_file_exists "$PROJ/just-plug/aws.just" "second module installed"

# Name collision: rival/docker would collide with demo/just-docker → should fail.
if just plug install github.com/rival/docker 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: name collision should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi
# Existing install must be untouched.
if diff -q <(printf '%s' "$CONTENT") just-plug/docker.just >/dev/null 2>&1; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: collision should leave docker.just untouched"
fi

# Default ref (no @ref) installs from main.
fixture_add_module "demo/just-redis" "redis.just" "v0.0.1" "ping:
    @echo pong
"
just plug install github.com/demo/just-redis
assert_file_exists "$PROJ/just-plug/redis.just" "default-ref install works"
deps_redis="$(awk '$1 == "redis"' just-plug.deps)"
assert_contains "$deps_redis" "main" "default ref is main"

assert_exit
