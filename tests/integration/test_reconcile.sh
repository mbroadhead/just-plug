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

fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "docker"
fixture_add_module "demo/just-aws"    "aws.just"    "v0.1.0" "aws"

cd "$PROJ"

# Hand-write a deps file WITHOUT running init (simulating: cloned a project
# where just-plug/ is gitignored — only just-plug.deps is committed).
cat > just-plug.deps <<'EOF'
docker  github.com/demo/just-docker  v1.0.0
aws     github.com/demo/just-aws     v0.1.0
EOF

# No-arg install reconciles: must create just-plug/ itself before fetching.
just plug install
assert_file_exists "$PROJ/just-plug" "reconcile creates just-plug/ when missing"
assert_file_exists "$PROJ/just-plug/docker.just" "docker installed by reconcile"
assert_file_exists "$PROJ/just-plug/aws.just" "aws installed by reconcile"
assert_contains "$(cat just-plug.lock)" "docker github.com/demo/just-docker v1.0.0" "lock has docker"
assert_contains "$(cat just-plug.lock)" "aws github.com/demo/just-aws v0.1.0" "lock has aws"
assert_contains "$(cat just-plug/modules.just)" 'mod? docker' "modules.just has docker"

# Orphan removal: drop aws from deps, reconcile, aws file and lock entry should go.
cat > just-plug.deps <<'EOF'
docker  github.com/demo/just-docker  v1.0.0
EOF
just plug install
assert_file_missing "$PROJ/just-plug/aws.just" "aws file removed as orphan"
lock="$(cat just-plug.lock)"
case "$lock" in
    *aws*) ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "FAIL: aws still in lock" ;;
    *) ASSERT_OK=$((ASSERT_OK + 1)) ;;
esac
mods="$(cat just-plug/modules.just)"
case "$mods" in
    *aws*) ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "FAIL: aws still in modules.just" ;;
    *) ASSERT_OK=$((ASSERT_OK + 1)) ;;
esac

# Idempotency: running again with no changes leaves state stable.
sha_before="$(awk '$1 == "docker" {print $4}' just-plug.lock)"
just plug install
sha_after="$(awk '$1 == "docker" {print $4}' just-plug.lock)"
assert_eq "$sha_before" "$sha_after" "reconcile is idempotent (no SHA churn)"

assert_exit
