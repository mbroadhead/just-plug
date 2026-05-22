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

url() { (cd "$TMP" && just plug _source-to-url "$1"); }

# Bare form: prepend default GitHub base.
out="$(url 'github.com/foo/just-docker')"
assert_eq "https://github.com/foo/just-docker" "$out" "bare form → default GitHub URL"

# Bare form with JUST_PLUG_GIT_BASE override.
out="$(JUST_PLUG_GIT_BASE='file:///tmp/fix' url 'github.com/foo/just-docker')"
assert_eq "file:///tmp/fix/foo/just-docker" "$out" "bare form respects JUST_PLUG_GIT_BASE"

# HTTPS URL form: passed through.
out="$(url 'https://github.com/foo/just-docker')"
assert_eq "https://github.com/foo/just-docker" "$out" "https URL passed through"

# SSH URL form: passed through.
out="$(url 'git@github.com:foo/just-docker')"
assert_eq "git@github.com:foo/just-docker" "$out" "ssh URL passed through"

# file:// URL form: passed through.
out="$(url 'file:///tmp/just-fixture')"
assert_eq "file:///tmp/just-fixture" "$out" "file URL passed through"

assert_exit
