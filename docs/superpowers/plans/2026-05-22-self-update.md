# `self-update` recipe implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `self-update` recipe to `plug.just` that fetches a newer (or pinned, or forked) version of `plug.just` and atomically replaces the local copy.

**Architecture:** The recipe reuses the existing `_parse-source` / `_resolve-ref` / `_fetch` helpers, so URL forms and private repos work the same way they do for `install`. It expands two shorthand input forms (empty → default; `@<ref>` → default-source@ref) before parsing. The fetched file is written to a temp path next to the target, compared with `cmp -s`, and either reported as up-to-date or moved over the target with `mv` (atomic on the same filesystem).

**Tech Stack:** just (justfile), bash, git, the existing `tests/lib/{fixture,assert}.sh` harness.

---

## File Structure

- **`plug.just`** — add the `self-update` recipe (one new top-level recipe, ~25 lines). Insert immediately before the existing `init` recipe, since both deal with the just-plug installation itself rather than user modules.
- **`tests/integration/test_self_update.sh`** — new integration test that uses a `file://` fixture repo so it runs offline.
- **`README.md`** — add a two-line example under `## Usage` near the bottom.

No other files change. Existing helpers (`_parse-source`, `_resolve-ref`, `_fetch`) are used unchanged.

---

### Task 1: Failing integration test

**Files:**
- Create: `tests/integration/test_self_update.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/integration/test_self_update.sh` with this exact content:

```bash
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

assert_exit
```

Make it executable:

```bash
chmod +x /Users/mitch/src/pmtbox/just-plug/tests/integration/test_self_update.sh
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/mitch/src/pmtbox/just-plug && bash tests/integration/test_self_update.sh
```

Expected: failure. The error should be either `Justfile does not contain recipe 'self-update'` or `error: just-plug: ... no recipe named self-update`. This proves the test exercises the new recipe.

- [ ] **Step 3: Commit the failing test**

```bash
cd /Users/mitch/src/pmtbox/just-plug
git add tests/integration/test_self_update.sh
git commit -m "test: failing integration test for self-update recipe"
```

---

### Task 2: Implement the `self-update` recipe

**Files:**
- Modify: `/Users/mitch/src/pmtbox/just-plug/plug.just` (insert one new recipe immediately before the `init` recipe)

- [ ] **Step 1: Add the recipe**

Open `plug.just`. Find the line `# Bootstrap a project for just-plug. Idempotent.` (just above `init:`). Insert the following block *immediately before that comment line*, leaving a blank line between the new recipe and the existing `init` comment:

```just
# Update just-plug itself. Defaults to github.com/mbroadhead/just-plug@main.
# Accepts the same spec forms as `install`, plus a bare `@<ref>` shorthand.
self-update spec="":
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'
    spec='{{spec}}'

    # Expand shorthand: empty or bare @<ref> → default source.
    if [ -z "$spec" ]; then
        spec="github.com/mbroadhead/just-plug@main"
    elif [[ "$spec" == @* ]]; then
        spec="github.com/mbroadhead/just-plug${spec}"
    fi

    parsed="$(just --justfile "$jf" plug _parse-source "$spec")"
    read -r _ source ref <<<"$parsed"

    sha="$(just --justfile "$jf" plug _resolve-ref "$source" "$ref")"
    short_sha="${sha:0:7}"

    target="$root/just-plug/plug.just"
    tmp="$(mktemp "${target}.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    just --justfile "$jf" plug _fetch "$source" "$sha" plug.just "$tmp" >/dev/null

    if [ -f "$target" ] && cmp -s "$target" "$tmp"; then
        echo "just-plug is up to date at $short_sha"
        exit 0
    fi

    mv "$tmp" "$target"
    trap - EXIT
    echo "updated just-plug → $short_sha ($source@$ref)"
```

- [ ] **Step 2: Run the integration test — expect pass**

```bash
cd /Users/mitch/src/pmtbox/just-plug && bash tests/integration/test_self_update.sh
```

Expected output ends with: `N assertion(s) passed` (where N is 3 — first-run update message, marker-line gone, second-run up-to-date message), exit code 0.

If the test fails, do not move on. Diagnose:
- "no recipe `_parse-source`" → the recipe insertion landed in the wrong place; re-check that it's inside `plug.just`, not a child file.
- "error: URL must have a path component" → the shorthand expansion is wrong; print `$spec` after the expansion block to inspect.
- File still has marker → the `mv` didn't happen; check that `cmp -s` is not returning 0 when it shouldn't.

- [ ] **Step 3: Run the full integration suite — confirm no regressions**

```bash
cd /Users/mitch/src/pmtbox/just-plug && just -f tests/justfile integration
```

Expected: every `=== tests/integration/test_*.sh ===` block ends with `N assertion(s) passed`, and the final exit code is 0.

- [ ] **Step 4: Verify the recipe shows up in help**

```bash
cd /Users/mitch/src/pmtbox/just-plug && (
  TMP=$(mktemp -d) && cd "$TMP" && \
  printf 'mod? plug "/Users/mitch/src/pmtbox/just-plug/plug.just"\n' > justfile && \
  just plug help && cd / && rm -rf "$TMP"
)
```

Expected: the listing now includes a `self-update` line with the description from the recipe's leading comment.

- [ ] **Step 5: Commit**

```bash
cd /Users/mitch/src/pmtbox/just-plug
git add plug.just
git commit -m "feat: add self-update recipe to update plug.just in place"
```

---

### Task 3: README update

**Files:**
- Modify: `/Users/mitch/src/pmtbox/just-plug/README.md` (add two new lines under `## Usage`, after the `outdated` example and before the `Reconcile` example)

- [ ] **Step 1: Add the usage example**

In `README.md`, find this block:

```sh
# Check whether any modules have newer versions available.
just plug outdated

# Reconcile: install everything in just-plug.deps, remove orphans.
just plug install
```

Replace it with:

```sh
# Check whether any modules have newer versions available.
just plug outdated

# Update just-plug itself (defaults to mbroadhead/just-plug@main).
just plug self-update
just plug self-update @v1.0.0

# Reconcile: install everything in just-plug.deps, remove orphans.
just plug install
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mitch/src/pmtbox/just-plug
git add README.md
git commit -m "docs: document self-update in README"
```

---

### Task 4: Final verification

- [ ] **Step 1: Run the full test suite (unit + integration)**

```bash
cd /Users/mitch/src/pmtbox/just-plug && just -f tests/justfile test
```

Expected: every test block reports `N assertion(s) passed`, and the final exit code is 0.

- [ ] **Step 2: Sanity-check the git log**

```bash
cd /Users/mitch/src/pmtbox/just-plug && git log --oneline -6
```

Expected: top three commits are (newest first) the README commit, the recipe commit, and the failing-test commit. Below them: the spec commit (`docs: spec for self-update recipe`) and the help/default commit from earlier in this session.

No further commits required. Branch is ready to push when the user asks.
