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

# Empty case: missing file → empty output.
out="$(cd "$TMP" && just plug _read-deps)"
assert_eq "" "$out" "missing deps reads empty"

out="$(cd "$TMP" && just plug _read-lock)"
assert_eq "" "$out" "missing lock reads empty"

# Populated deps file with comments and blanks.
cat > "$TMP/just-plug.deps" <<'EOF'
# this is a comment
docker    github.com/foo/docker      v1.2.0

aws       github.com/bar/aws         main
EOF
out="$(cd "$TMP" && just plug _read-deps)"
expected="docker github.com/foo/docker v1.2.0
aws github.com/bar/aws main"
assert_eq "$expected" "$out" "deps read normalizes whitespace"

# Populated lock file (5 fields).
cat > "$TMP/just-plug.lock" <<'EOF'
docker    github.com/foo/docker      v1.2.0   abc123def4567890   sha256-x
EOF
out="$(cd "$TMP" && just plug _read-lock)"
assert_eq "docker github.com/foo/docker v1.2.0 abc123def4567890 sha256-x" "$out" "lock read"

assert_exit
