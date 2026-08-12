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

entry() { (cd "$TMP" && just plug _entry-file "$1"); }

# The remote entry filename follows the repo basename, never the local module
# name — which --as can change.
assert_eq "docker.just" "$(entry 'github.com/foo/just-docker')" "bare form, just- prefix"
assert_eq "docker.just" "$(entry 'github.com/foo/docker')" "bare form, no prefix"
assert_eq "docker.just" "$(entry 'https://github.com/foo/just-docker')" "https form"
assert_eq "docker.just" "$(entry 'git@github.com:foo/just-docker')" "ssh form"
assert_eq "docker.just" "$(entry 'file:///tmp/fixtures/just-docker')" "file form"

# Sources are stored normalized, but tolerate a stray .git or trailing slash.
assert_eq "docker.just" "$(entry 'https://github.com/foo/just-docker.git')" "trailing .git"
assert_eq "docker.just" "$(entry 'github.com/foo/just-docker/')" "trailing slash"

# A repo basename that is itself just- prefixed twice only loses one prefix.
assert_eq "just-docker.just" "$(entry 'github.com/foo/just-just-docker')" "one prefix stripped"

assert_exit
