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

# HTTPS URL form: store as-typed sans .git, default ref main.
out="$(parse 'https://github.com/foo/just-docker')"
assert_eq "docker https://github.com/foo/just-docker main" "$out" "https url, default ref"

# HTTPS URL form with .git suffix: strip .git.
out="$(parse 'https://github.com/foo/just-docker.git')"
assert_eq "docker https://github.com/foo/just-docker main" "$out" "https url, strip .git"

# HTTPS URL form with .git and ref.
out="$(parse 'https://github.com/foo/just-docker.git@v1.2.0')"
assert_eq "docker https://github.com/foo/just-docker v1.2.0" "$out" "https url with .git and tag"

# HTTPS URL form with ref, no .git.
out="$(parse 'https://github.com/foo/just-docker@develop')"
assert_eq "docker https://github.com/foo/just-docker develop" "$out" "https url with branch ref"

# HTTPS URL with userinfo + ref — @ in userinfo must not be confused with @ref.
out="$(parse 'https://user:pass@github.com/foo/just-docker@v1.2.0')"
assert_eq "docker https://user:pass@github.com/foo/just-docker v1.2.0" "$out" "userinfo @ preserved, ref correctly split"

# SSH URL form: store as-typed sans .git, default ref main.
out="$(parse 'git@github.com:foo/just-docker')"
assert_eq "docker git@github.com:foo/just-docker main" "$out" "ssh url, default ref"

# SSH URL form with .git: strip .git.
out="$(parse 'git@github.com:foo/just-docker.git')"
assert_eq "docker git@github.com:foo/just-docker main" "$out" "ssh url, strip .git"

# SSH URL form with .git and ref.
out="$(parse 'git@github.com:foo/just-docker.git@v1.2.0')"
assert_eq "docker git@github.com:foo/just-docker v1.2.0" "$out" "ssh url with .git and tag"

# SSH URL form with ref, no .git.
out="$(parse 'git@github.com:foo/just-docker@develop')"
assert_eq "docker git@github.com:foo/just-docker develop" "$out" "ssh url with branch ref"

# file:// URL form.
out="$(parse 'file:///tmp/just-fixture')"
assert_eq "fixture file:///tmp/just-fixture main" "$out" "file URL form"

# Invalid HTTPS URL: missing repo path segment.
if parse 'https://github.com/foo' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: https url without repo segment should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Invalid SSH URL: missing repo path.
if parse 'git@github.com:foo' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: ssh url without repo segment should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
