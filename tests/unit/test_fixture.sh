#!/usr/bin/env bash
# Verifies the fixture helper can stand up a bare repo, serve raw content,
# and tear everything down cleanly.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT

# Spin up a fixture repo containing one tagged file.
fixture_setup "$TMP"
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" 'show:
    @echo hi
'

# git ls-remote should find the tag.
SHA="$(git ls-remote "$JUST_PLUG_GIT_BASE/demo/just-docker" "refs/tags/v1.0.0" | awk '{print $1}')"
assert_eq 40 "${#SHA}" "ls-remote returns a 40-char SHA"

# Raw HTTP server should serve docker.just at the tag's SHA path.
BODY="$(curl -fsSL "$JUST_PLUG_RAW_BASE/demo/just-docker/$SHA/docker.just")"
assert_contains "$BODY" "show:" "raw HTTP returns the module file"

assert_exit
