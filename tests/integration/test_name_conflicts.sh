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
fixture_add_module "demo/just-broken"   "broken.just"    "v1.0.0" 'this is (not ]] valid just
'

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
# init writes just-plug.deps but not the lockfile, so tolerate its absence here.
assert_eq "" "$(awk '$1 == "doit"' just-plug.lock 2>/dev/null || true)" "collision leaves no lock entry"

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

# --- A module that is itself unparseable breaks the justfile in a way no name
# check can predict, so the install rolls itself back.
out="$(just plug install github.com/demo/just-broken 2>&1 || true)"
assert_contains "$out" "rolled back" "unparseable module is rolled back"
assert_file_missing "$PROJ/just-plug/broken.just" "rollback deletes the module file"
assert_eq "" "$(awk '$1 == "broken"' just-plug.deps)" "rollback clears the deps entry"
assert_eq "" "$(awk '$1 == "broken"' just-plug.lock)" "rollback clears the lock entry"
assert_eq "" "$(grep 'broken' just-plug/modules.just || true)" "rollback clears the modules.just entry"
assert_contains "$(just --summary)" "doit" "justfile parses again after rollback"

# --- Re-installing an already-installed module at a new ref is not a collision
# with itself, even though its name is in modules.just by then.
just plug install github.com/demo/just-doit@v1.0.0 --as tasks >/dev/null
fixture_add_module "demo/just-doit" "doit.just" "v2.0.0" 'run:
    @echo "module doit v2"
'
just plug install github.com/demo/just-doit@v2.0.0 --as tasks >/dev/null
assert_contains "$(cat just-plug.deps)" "tasks github.com/demo/just-doit v2.0.0" "re-pin to a new ref works"
just plug remove tasks >/dev/null

# --- Installing the same name from a different source still refuses, now with --as.
# (v2.0.0: re-adding the fixture above rebuilt the repo, dropping the v1.0.0 tag.)
just plug install github.com/demo/just-doit@v2.0.0 --as tasks >/dev/null
fixture_add_module "rival/just-doit" "doit.just" "v1.0.0" "$CONTENT"
out="$(just plug install github.com/rival/just-doit --as tasks 2>&1 || true)"
assert_contains "$out" "--as" "different-source collision suggests --as"
assert_contains "$(cat just-plug.lock)" "github.com/demo/just-doit" "original install untouched"
just plug remove tasks >/dev/null

# --- Reconcile mode can break the justfile the same way, and is the likelier way
# to hit it: `mod?`/`import?` are optional, so a checkout whose justfile shadows a
# name in just-plug.deps parses fine right up until someone runs a bare
# `just plug install` and modules.just appears. That must roll back too.
echo "doit github.com/demo/just-doit v2.0.0" >> just-plug.deps
lock_before="$(cat just-plug.lock)"
out="$(just plug install 2>&1 || true)"
assert_contains "$out" "rolled back" "reconcile rolls back a colliding dep"
assert_file_missing "$PROJ/just-plug/doit.just" "reconcile rollback deletes the fetched file"
assert_eq "" "$(grep 'doit' just-plug/modules.just || true)" "reconcile rollback clears modules.just"
assert_eq "$lock_before" "$(cat just-plug.lock)" "reconcile rollback restores the lockfile"
assert_contains "$(just --summary)" "doit" "justfile parses again after reconcile rollback"
# just-plug.deps is the user's file, so the rollback leaves it as they wrote it —
# the conflict is still there to fix, and reconcile is not the thing to fix it.
assert_contains "$(cat just-plug.deps)" "doit github.com/demo/just-doit" "reconcile leaves deps alone"
sed -i.bak '/^doit /d' just-plug.deps && rm -f just-plug.deps.bak

# --- Rescue: nothing stops a user adding a recipe that shadows a module they
# already installed. That breaks every just command in the project, `just plug
# remove` included, so plug.just has to be runnable on its own. Appending to the
# justfile is destructive to the cases above — keep this block last.
just plug install github.com/demo/just-doit@v2.0.0 --as shadowed >/dev/null
cat >> justfile <<'EOF'

shadowed:
    @echo "added later"
EOF
if just --summary >/dev/null 2>&1; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: a shadowed module should break the justfile"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

JUST_PLUG_DIR="$PROJ" just -f "$PLUG" remove shadowed >/dev/null
assert_file_missing "$PROJ/just-plug/shadowed.just" "rescue removes the module file"
assert_eq "" "$(awk '$1 == "shadowed"' just-plug.deps)" "rescue clears the deps entry"
assert_eq "" "$(awk '$1 == "shadowed"' just-plug.lock)" "rescue clears the lock entry"
assert_contains "$(just --summary)" "shadowed" "the project justfile parses again"

assert_exit
