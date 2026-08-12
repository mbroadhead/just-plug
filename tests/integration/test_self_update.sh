#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/fixture.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'fixture_teardown; rm -rf "$TMP"' EXIT
fixture_setup "$TMP/fix"

# Fixture serves the real plug.just at tag v0.99.0.
PLUG_CONTENT="$(cat "$PLUG")"
fixture_add_module "mbroadhead/just-plug" "plug.just" "v0.99.0" "$PLUG_CONTENT"

# Set up a project whose installed plug.just is the real one plus a marker
# line. self-update should replace the file and lose the marker.
PROJ="$TMP/proj"
mkdir -p "$PROJ/just-plug"
INSTALLED_CONTENT="$PLUG_CONTENT
# fixture-marker-line"
printf '%s' "$INSTALLED_CONTENT" > "$PROJ/just-plug/plug.just"
cat > "$PROJ/justfile" <<EOF
mod? plug "just-plug/plug.just"
EOF

URL="file://${_FIXTURE_GIT_ROOT}/mbroadhead/just-plug"

cd "$PROJ"

# First update — file should change.
out="$(just plug self-update "${URL}@v0.99.0")"
assert_contains "$out" "updated just-plug" "first run reports update"
if grep -qF "fixture-marker-line" just-plug/plug.just; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: marker line still present after update"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Second update — idempotent.
out="$(just plug self-update "${URL}@v0.99.0")"
assert_contains "$out" "up to date" "second run reports up to date"

# --- self-update rewrites the file the justfile actually loads, wherever that is.
# A project pointing `mod plug` somewhere other than just-plug/plug.just used to
# get a success message for a write to a file nothing reads.
ALT="$TMP/alt"
mkdir -p "$ALT/lib" "$ALT/just-plug"
printf '%s' "$INSTALLED_CONTENT" > "$ALT/lib/plug.just"
# A stale copy at the conventional path: the decoy self-update used to write to.
printf '%s' "$INSTALLED_CONTENT" > "$ALT/just-plug/plug.just"
cat > "$ALT/justfile" <<EOF
mod? plug "lib/plug.just"
EOF
cd "$ALT"
out="$(just plug self-update "${URL}@v0.99.0" 2>&1)"
assert_contains "$out" "updated just-plug" "self-update reports an update in a custom layout"
if grep -qF "fixture-marker-line" lib/plug.just; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: the loaded copy was not updated"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi
assert_contains "$(cat just-plug/plug.just)" "fixture-marker-line" "the unused copy is left alone"
assert_contains "$out" "is unused" "the unused copy is called out"

# --- An absolute `mod plug` path inside the project is still inside it, even when
# it reaches the project through a symlink (/tmp and /var are symlinks on macOS).
LINKED="$TMP/linked"
mkdir -p "$LINKED/real/lib"
ln -s real "$LINKED/via"
printf '%s' "$INSTALLED_CONTENT" > "$LINKED/real/lib/plug.just"
cat > "$LINKED/real/justfile" <<EOF
mod? plug "$LINKED/via/lib/plug.just"
EOF
cd "$LINKED/real"
out="$(just plug self-update "${URL}@v0.99.0" 2>&1 || true)"
assert_contains "$out" "updated just-plug" "a symlinked path inside the project is not refused"

# --- A copy outside the project is not this project's to overwrite.
SHARED="$TMP/shared"
mkdir -p "$SHARED"
printf '%s' "$INSTALLED_CONTENT" > "$SHARED/plug.just"
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
cat > "$OUTSIDE/justfile" <<EOF
mod? plug "$SHARED/plug.just"
EOF
cd "$OUTSIDE"
out="$(just plug self-update "${URL}@v0.99.0" 2>&1 || true)"
assert_contains "$out" "loaded from outside" "a shared copy is refused"
assert_contains "$(cat "$SHARED/plug.just")" "fixture-marker-line" "the shared copy is untouched"

# --- ...but naming it directly is how you update it, so the message is runnable.
out="$(just -f "$SHARED/plug.just" self-update "${URL}@v0.99.0" 2>&1)"
assert_contains "$out" "updated just-plug" "the standalone form updates a shared copy"
if grep -qF "fixture-marker-line" "$SHARED/plug.just"; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: standalone self-update did not rewrite the file"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

assert_exit
