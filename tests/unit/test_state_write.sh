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

# Upsert into empty deps.
just plug _upsert-dep docker github.com/foo/docker v1.2.0
out="$(just plug _read-deps)"
assert_eq "docker github.com/foo/docker v1.2.0" "$out" "insert into empty deps"

# Upsert second module; output sorted by name.
just plug _upsert-dep aws github.com/bar/aws main
out="$(just plug _read-deps)"
expected="aws github.com/bar/aws main
docker github.com/foo/docker v1.2.0"
assert_eq "$expected" "$out" "deps sorted by name"

# Upsert overwrites by name (same name, new ref).
just plug _upsert-dep docker github.com/foo/docker v2.0.0
out="$(just plug _read-deps)"
expected="aws github.com/bar/aws main
docker github.com/foo/docker v2.0.0"
assert_eq "$expected" "$out" "upsert overwrites by name"

# Remove.
just plug _remove-dep aws
out="$(just plug _read-deps)"
assert_eq "docker github.com/foo/docker v2.0.0" "$out" "remove by name"

# Same operations for lock.
just plug _upsert-lock docker github.com/foo/docker v2.0.0 abc123 sha256-x
out="$(just plug _read-lock)"
assert_eq "docker github.com/foo/docker v2.0.0 abc123 sha256-x" "$out" "lock upsert"

just plug _remove-lock docker
out="$(just plug _read-lock)"
assert_eq "" "$out" "lock remove"

assert_exit
