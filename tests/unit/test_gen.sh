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
mkdir -p just-plug

# Empty lock → empty modules.just (or no file? we choose: write empty file).
just plug _gen-modules
assert_file_exists "$TMP/just-plug/modules.just" "modules.just written even when empty"
assert_eq "" "$(cat just-plug/modules.just)" "empty when no lock entries"

# Populated lock.
cat > "$TMP/just-plug.lock" <<'EOF'
docker  github.com/foo/docker  v1.2.0  abc123  sha256-x
aws     github.com/bar/aws     main    789xyz  sha256-y
EOF
just plug _gen-modules
expected='mod? aws "aws.just"
mod? docker "docker.just"'
assert_eq "$expected" "$(cat just-plug/modules.just)" "modules.just sorted by name"

assert_exit
