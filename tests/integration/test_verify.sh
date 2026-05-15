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
fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" "x"
fixture_add_module "demo/just-aws"    "aws.just"    "v0.1.0" "y"

cd "$PROJ"
just plug init >/dev/null
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
just plug install github.com/demo/just-aws@v0.1.0 >/dev/null

# Clean state: verify passes.
just plug verify
ASSERT_OK=$((ASSERT_OK + 1))

# Tampered file: verify fails non-zero, names the offender.
echo "tampered" >> just-plug/docker.just
verify_out="$(just plug verify 2>&1 || true)"
if echo "$verify_out" | grep -q docker; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: verify did not name docker on tamper"
fi
if just plug verify >/dev/null 2>&1; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: verify should exit non-zero"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Restore docker and verify the other case: missing file.
rm just-plug/docker.just
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
rm just-plug/aws.just
verify_out2="$(just plug verify 2>&1 || true)"
if echo "$verify_out2" | grep -q aws; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: verify did not name aws on missing"
fi
if just plug verify >/dev/null 2>&1; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: verify should exit non-zero for missing file"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
