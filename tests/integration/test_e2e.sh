#!/usr/bin/env bash
# End-to-end smoke: simulate a user's bootstrap and full workflow against fixture repos.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG_SRC="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

# Simulate fresh user project.
PROJ="$TMP/myproj"
mkdir -p "$PROJ/just-plug"
cp "$PLUG_SRC" "$PROJ/just-plug/plug.just"

cat > "$PROJ/justfile" <<'EOF'
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"

hello:
    @echo "user recipe"
EOF

fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" 'ps:
    @echo "docker ps"
'

cd "$PROJ"

# 1. init.
just plug init >/dev/null

# 2. install a module.
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null

# 3. The user's `just docker ps` should now work.
out="$(just docker ps)"
assert_eq "docker ps" "$out" "installed module recipe is runnable"

# 4. The user's own recipes still work.
out="$(just hello)"
assert_eq "user recipe" "$out" "user's own recipes unaffected"

# 5. List.
out="$(just plug list)"
assert_contains "$out" "docker" "list shows installed module"

# 6. Verify clean.
just plug verify >/dev/null
ASSERT_OK=$((ASSERT_OK + 1))

# 7. Remove and re-run hello (still works).
just plug remove docker >/dev/null
out="$(just hello)"
assert_eq "user recipe" "$out" "user recipes still work after remove"

# 8. Trying to use docker recipe should now fail.
if just docker ps 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: docker recipe should be gone"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
