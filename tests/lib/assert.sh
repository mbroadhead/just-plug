# tests/lib/assert.sh — minimal assertion helpers. Source this from test scripts.

set -euo pipefail

# Track test results.
ASSERT_OK=0
ASSERT_FAIL=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [ "$expected" = "$actual" ]; then
        ASSERT_OK=$((ASSERT_OK + 1))
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        echo "FAIL: ${msg:-assert_eq}"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        ASSERT_OK=$((ASSERT_OK + 1))
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        echo "FAIL: ${msg:-assert_contains}"
        echo "  haystack: $haystack"
        echo "  needle:   $needle"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-}"
    if [ -e "$path" ]; then
        ASSERT_OK=$((ASSERT_OK + 1))
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        echo "FAIL: ${msg:-assert_file_exists}"
        echo "  missing path: $path"
    fi
}

assert_file_missing() {
    local path="$1"
    local msg="${2:-}"
    if [ ! -e "$path" ]; then
        ASSERT_OK=$((ASSERT_OK + 1))
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        echo "FAIL: ${msg:-assert_file_missing}"
        echo "  unexpectedly present: $path"
    fi
}

assert_exit() {
    if [ "$ASSERT_FAIL" -gt 0 ]; then
        echo "$ASSERT_FAIL assertion(s) failed, $ASSERT_OK passed"
        exit 1
    fi
    echo "$ASSERT_OK assertion(s) passed"
}
