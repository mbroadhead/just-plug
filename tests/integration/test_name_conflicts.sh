#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

CONTENT='run:
    @echo "module doit"
'
fixture_add_module "demo/just-doit"     "doit.just"      "v1.0.0" "$CONTENT"
fixture_add_module "demo/just-my.thing" "my.thing.just"  "v1.0.0" "$CONTENT"

# A project with a `doit` recipe of its own. Installing demo/just-doit here
# would derive the module name `doit` and make the whole justfile unparseable.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/justfile" <<EOF
mod? plug "$PLUG"
import? "just-plug/modules.just"

doit:
    @echo "local doit"

[private]
hidden:
    @echo hidden
EOF

cd "$PROJ"
just plug init >/dev/null

# --- Collision with an existing recipe is refused, with the fix in the message.
out="$(just plug install github.com/demo/just-doit 2>&1 || true)"
assert_contains "$out" "--as" "collision error suggests --as"
assert_file_missing "$PROJ/just-plug/doit.just" "collision leaves no module file"
assert_eq "" "$(awk '$1 == "doit"' just-plug.deps)" "collision leaves no deps entry"
assert_eq "" "$(awk '$1 == "doit"' just-plug.lock)" "collision leaves no lock entry"

# A private recipe shadows just as fatally, and `just --summary` hides it.
out="$(just plug install github.com/demo/just-doit --as hidden 2>&1 || true)"
assert_contains "$out" "--as" "private-recipe collision is caught too"
assert_file_missing "$PROJ/just-plug/hidden.just" "private collision installs nothing"

# --- The same install under a chosen name succeeds.
just plug install github.com/demo/just-doit@v1.0.0 --as tasks
assert_file_exists "$PROJ/just-plug/tasks.just" "aliased module file uses the local name"
assert_file_missing "$PROJ/just-plug/doit.just" "remote filename is not used locally"
assert_contains "$(cat just-plug.deps)" "tasks github.com/demo/just-doit v1.0.0" "deps keyed by alias"
assert_contains "$(cat just-plug.lock)" "tasks github.com/demo/just-doit v1.0.0" "lock keyed by alias"
assert_contains "$(cat just-plug/modules.just)" 'mod? tasks "tasks.just"' "modules.just keyed by alias"

# The justfile still parses, and both names resolve.
assert_contains "$(just --summary)" "tasks::run" "aliased module recipe is reachable"
assert_contains "$(just doit)" "local doit" "local recipe still works"

# --- update refetches by alias (the remote file is still doit.just).
rm -f "$PROJ/just-plug/tasks.just"
just plug update tasks >/dev/null
assert_file_exists "$PROJ/just-plug/tasks.just" "update refetches an aliased module"

# --- reconcile refetches by alias too.
rm -f "$PROJ/just-plug/tasks.just"
just plug install >/dev/null
assert_file_exists "$PROJ/just-plug/tasks.just" "reconcile refetches an aliased module"

# --- remove works on the local name.
just plug remove tasks >/dev/null
assert_file_missing "$PROJ/just-plug/tasks.just" "remove deletes the aliased file"
assert_eq "" "$(awk '$1 == "tasks"' just-plug.deps)" "remove clears the deps entry"

# --- A source deriving an illegal module name is refused.
out="$(just plug install github.com/demo/just-my.thing 2>&1 || true)"
assert_contains "$out" "--as" "illegal derived name suggests --as"
assert_file_missing "$PROJ/just-plug/my.thing.just" "illegal name installs nothing"

# --- An illegal alias is refused on the same grounds.
out="$(just plug install github.com/demo/just-doit --as 'my.thing' 2>&1 || true)"
assert_contains "$out" "not a valid module name" "illegal alias is rejected"

# --- Unknown options and a bare --as are errors, not silent no-ops.
if just plug install github.com/demo/just-doit --nope 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: unknown option should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi
out="$(just plug install --as tasks 2>&1 || true)"
assert_contains "$out" "requires a source" "--as without a spec is an error"

# --- Installing the same name from a different source still refuses, now with --as.
just plug install github.com/demo/just-doit@v1.0.0 --as tasks >/dev/null
fixture_add_module "rival/just-doit" "doit.just" "v1.0.0" "$CONTENT"
out="$(just plug install github.com/rival/just-doit --as tasks 2>&1 || true)"
assert_contains "$out" "--as" "different-source collision suggests --as"
assert_contains "$(cat just-plug.lock)" "github.com/demo/just-doit" "original install untouched"

assert_exit
