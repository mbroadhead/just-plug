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
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "v1"

cd "$PROJ"
just plug init >/dev/null
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null

# Initially: not outdated.
out="$(just plug outdated)"
assert_contains "$out" "up to date" "no outdated modules"

# Add a newer tag in the fixture.
WORK="$TMP/fix/work/demo/just-docker"
(cd "$WORK"
 printf 'v2' > docker.just
 git -c user.email=t@t -c user.name=t commit -q -am v2
 git tag v2.0.0
 git push "$TMP/fix/git/demo/just-docker" main >/dev/null 2>&1 || true
 git push --tags "$TMP/fix/git/demo/just-docker" >/dev/null 2>&1
)

out="$(just plug outdated)"
assert_contains "$out" "docker" "docker reported"
assert_contains "$out" "v2.0.0" "v2.0.0 reported as newer"

# Branch pin: install at main, then push a new commit.
fixture_add_module "demo/just-aws" "aws.just" "v0.1.0" "a1"
just plug install github.com/demo/just-aws >/dev/null  # default ref = main

WORK="$TMP/fix/work/demo/just-aws"
(cd "$WORK"
 printf 'a2' > aws.just
 git -c user.email=t@t -c user.name=t commit -q -am a2
 git push "$TMP/fix/git/demo/just-aws" main >/dev/null 2>&1
)

out="$(just plug outdated)"
assert_contains "$out" "aws" "branch-pinned module reported as outdated"

assert_exit
