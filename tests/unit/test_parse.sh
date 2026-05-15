#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"

PLUG="$HERE/../../plug.just"

# Set up a temp project so just can find plug.just via mod.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/justfile" <<EOF
mod? plug "$PLUG"
EOF

parse() { (cd "$TMP" && just plug _parse-source "$1"); }

# github.com/foo/just-docker → name=docker, source as given, ref=main
out="$(parse 'github.com/foo/just-docker')"
assert_eq "docker github.com/foo/just-docker main" "$out" "strip just- prefix, default ref"

# Without just- prefix
out="$(parse 'github.com/foo/docker')"
assert_eq "docker github.com/foo/docker main" "$out" "no prefix"

# With @ref
out="$(parse 'github.com/foo/just-docker@v1.2.0')"
assert_eq "docker github.com/foo/just-docker v1.2.0" "$out" "tag ref"

# With branch
out="$(parse 'github.com/foo/just-docker@develop')"
assert_eq "docker github.com/foo/just-docker develop" "$out" "branch ref"

# Invalid: not github.com
if parse 'gitlab.com/foo/bar' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: gitlab source should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Invalid: missing owner or repo
if parse 'github.com/foo' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: incomplete source should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
