# JUST_PLUG_DIR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `JUST_PLUG_DIR` env var that relocates just-plug's artifacts (`just-plug.deps`, `just-plug.lock`, `just-plug/`) from `justfile_directory()` to a user-chosen directory.

**Architecture:** Each recipe is a self-contained bash script. We inline a 4-line resolution snippet wherever a recipe touches artifact paths: it reads `$JUST_PLUG_DIR` from the environment and, if set, overrides the existing `root` variable. Absolute paths are used as-is; relative paths are resolved against `justfile_directory()`. When `JUST_PLUG_DIR` is unset or empty, behavior is byte-identical to today.

**Tech Stack:** `just` (recipes), `bash` (recipe bodies), `python3 -m http.server` + bare git repos (test fixture).

**Spec:** `docs/superpowers/specs/2026-05-22-just-plug-dir.md`

---

## File Structure

- `tests/integration/test_just_plug_dir.sh` — new integration test (created in Task 1, extended in Task 4).
- `plug.just` — modified in Tasks 2, 3, 4. ~12 recipes affected. Each gets the same 4-line resolution snippet.
- `README.md` — modified in Task 5. New "Custom artifact location" section; "File layout" gets a one-line note.

Everything lives in one already-large `plug.just` file. The project has chosen to keep recipes in one file rather than split by concern; we follow that convention.

---

## The Resolution Snippet

Used in **every** recipe that touches artifact paths. Read this once; later tasks reference it as "**the resolution snippet**":

```bash
root='{{justfile_directory()}}'
if [ -n "${JUST_PLUG_DIR:-}" ]; then
    case "$JUST_PLUG_DIR" in
        /*) root="$JUST_PLUG_DIR" ;;
        *)  root="$root/$JUST_PLUG_DIR" ;;
    esac
fi
```

Notes:
- `${JUST_PLUG_DIR:-}` is the safe form under `set -u`.
- The `case` handles absolute (`/*`) and relative paths.
- `JUST_PLUG_DIR` is read from the environment at recipe runtime, not interpolated by `just` — avoids any quoting concerns if the value contains shell metacharacters.

---

## Task 1: Failing integration test for `JUST_PLUG_DIR`

**Files:**
- Create: `tests/integration/test_just_plug_dir.sh`

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration/test_just_plug_dir.sh` with this exact content:

```bash
#!/usr/bin/env bash
# Verifies JUST_PLUG_DIR relocates artifacts to a subdirectory.
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

fixture_add_module "demo/just-docker" "docker.just" "v1.0.0" 'show:
    @echo hi
'

cd "$PROJ"
export JUST_PLUG_DIR="tools"

# init places artifacts under tools/, not at project root.
just plug init >/dev/null
assert_file_exists "$PROJ/tools/just-plug"      "init created tools/just-plug dir"
assert_file_exists "$PROJ/tools/just-plug.deps" "init created tools/just-plug.deps"
assert_file_missing "$PROJ/just-plug"           "no just-plug dir at project root"
assert_file_missing "$PROJ/just-plug.deps"      "no deps file at project root"

# install routes through JUST_PLUG_DIR.
just plug install github.com/demo/just-docker@v1.0.0 >/dev/null
assert_file_exists "$PROJ/tools/just-plug/docker.just"   "module installed under tools/"
assert_file_exists "$PROJ/tools/just-plug.lock"          "lock written under tools/"
assert_file_exists "$PROJ/tools/just-plug/modules.just"  "modules.just written under tools/"
assert_file_missing "$PROJ/just-plug/docker.just"        "no module at project root"

# list / verify read relocated state.
out="$(just plug list)"
assert_contains "$out" "docker" "list reads relocated lock"

just plug verify >/dev/null
ASSERT_OK=$((ASSERT_OK + 1))

# remove deletes from relocated location.
just plug remove docker >/dev/null
assert_file_missing "$PROJ/tools/just-plug/docker.just" "remove deletes from relocated dir"

# Absolute path also works.
ABS="$TMP/abs"
PROJ2="$TMP/proj2"
mkdir -p "$PROJ2"
cat > "$PROJ2/justfile" <<EOF
mod? plug "$PLUG"
EOF
cd "$PROJ2"
export JUST_PLUG_DIR="$ABS"
just plug init >/dev/null
assert_file_exists "$ABS/just-plug"      "absolute-path init creates dir"
assert_file_exists "$ABS/just-plug.deps" "absolute-path init creates deps"
assert_file_missing "$PROJ2/just-plug"   "absolute path does not write under proj2"

assert_exit
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `bash tests/integration/test_just_plug_dir.sh`
Expected: first assertion fails because `just plug init` creates `$PROJ/just-plug` (project root), not `$PROJ/tools/just-plug`. Test exits non-zero.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/integration/test_just_plug_dir.sh
git commit -m "test: failing integration test for JUST_PLUG_DIR"
```

---

## Task 2: Resolve `JUST_PLUG_DIR` in helper recipes

These are the `_`-prefixed helpers that today reference `{{justfile_directory()}}` directly without binding a `root` variable. Eight recipes total. Each gets the resolution snippet, and every literal `{{justfile_directory()}}/...` becomes `"$root/..."`.

**Files:**
- Modify: `plug.just` — recipes `_paths`, `_read-deps`, `_read-lock`, `_upsert-dep`, `_remove-dep`, `_upsert-lock`, `_remove-lock`, `_gen-modules`.

- [ ] **Step 1: Rewrite `_paths` (`plug.just:17-23`)**

`_paths` today is `@echo` lines; converting to a bash script lets it compute the resolved root before printing.

Replace:

```just
# Print plug-internal paths. Used by tests; harmless for users.
_paths:
    @echo "ROOT={{justfile_directory()}}"
    @echo "DEPS={{justfile_directory()}}/just-plug.deps"
    @echo "LOCK={{justfile_directory()}}/just-plug.lock"
    @echo "PLUGDIR={{justfile_directory()}}/just-plug"
    @echo "MODSFILE={{justfile_directory()}}/just-plug/modules.just"
```

with:

```just
# Print plug-internal paths. Used by tests; harmless for users.
_paths:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    echo "ROOT=$root"
    echo "DEPS=$root/just-plug.deps"
    echo "LOCK=$root/just-plug.lock"
    echo "PLUGDIR=$root/just-plug"
    echo "MODSFILE=$root/just-plug/modules.just"
```

- [ ] **Step 2: Update `_read-deps`**

Replace:

```just
_read-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.deps'
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3}' "$f"
```

with:

```just
_read-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.deps"
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3}' "$f"
```

- [ ] **Step 3: Update `_read-lock`**

Replace:

```just
_read-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.lock'
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3, $4, $5}' "$f"
```

with:

```just
_read-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.lock"
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3, $4, $5}' "$f"
```

- [ ] **Step 4: Update `_upsert-dep`**

Replace:

```just
_upsert-dep name source ref:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.deps'
    name='{{name}}' source='{{source}}' ref='{{ref}}'
    tmp="$(mktemp "${f}.XXXXXX")"
    {
        # Carry over existing lines that don't match this name.
        if [ -f "$f" ]; then
            awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3}' "$f"
        fi
        echo "$name $source $ref"
    } | sort > "$tmp"
    mv "$tmp" "$f"
```

with:

```just
_upsert-dep name source ref:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.deps"
    name='{{name}}' source='{{source}}' ref='{{ref}}'
    tmp="$(mktemp "${f}.XXXXXX")"
    {
        # Carry over existing lines that don't match this name.
        if [ -f "$f" ]; then
            awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3}' "$f"
        fi
        echo "$name $source $ref"
    } | sort > "$tmp"
    mv "$tmp" "$f"
```

- [ ] **Step 5: Update `_remove-dep`**

Replace:

```just
_remove-dep name:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.deps'
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"
```

with:

```just
_remove-dep name:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.deps"
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"
```

- [ ] **Step 6: Update `_upsert-lock`**

Replace:

```just
_upsert-lock name source ref sha hash:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.lock'
    name='{{name}}' source='{{source}}' ref='{{ref}}' sha='{{sha}}' hash='{{hash}}'
    tmp="$(mktemp "${f}.XXXXXX")"
    {
        if [ -f "$f" ]; then
            awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3, $4, $5}' "$f"
        fi
        echo "$name $source $ref $sha $hash"
    } | sort > "$tmp"
    mv "$tmp" "$f"
```

with:

```just
_upsert-lock name source ref sha hash:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.lock"
    name='{{name}}' source='{{source}}' ref='{{ref}}' sha='{{sha}}' hash='{{hash}}'
    tmp="$(mktemp "${f}.XXXXXX")"
    {
        if [ -f "$f" ]; then
            awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3, $4, $5}' "$f"
        fi
        echo "$name $source $ref $sha $hash"
    } | sort > "$tmp"
    mv "$tmp" "$f"
```

- [ ] **Step 7: Update `_remove-lock`**

Replace:

```just
_remove-lock name:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.lock'
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3, $4, $5}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"
```

with:

```just
_remove-lock name:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    f="$root/just-plug.lock"
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3, $4, $5}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"
```

- [ ] **Step 8: Update `_gen-modules`**

Replace:

```just
_gen-modules:
    #!/usr/bin/env bash
    set -euo pipefail
    lock='{{justfile_directory()}}/just-plug.lock'
    out='{{justfile_directory()}}/just-plug/modules.just'
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp "${out}.XXXXXX")"
    if [ -f "$lock" ]; then
        awk 'NF && $1 !~ /^#/ {print "mod? " $1 " \"" $1 ".just\""}' "$lock" | sort > "$tmp"
    else
        : > "$tmp"
    fi
    mv "$tmp" "$out"
```

with:

```just
_gen-modules:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    lock="$root/just-plug.lock"
    out="$root/just-plug/modules.just"
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp "${out}.XXXXXX")"
    if [ -f "$lock" ]; then
        awk 'NF && $1 !~ /^#/ {print "mod? " $1 " \"" $1 ".just\""}' "$lock" | sort > "$tmp"
    else
        : > "$tmp"
    fi
    mv "$tmp" "$out"
```

- [ ] **Step 9: Run unit tests and confirm they still pass**

The helper-recipe unit tests run with `JUST_PLUG_DIR` unset, so the resolution snippet is a no-op and existing behavior must be byte-identical.

Run: `just -f tests/justfile unit`
Expected: all unit tests pass (look for `=== unit/test_*.sh ===` lines followed by `N assertion(s) passed` and a clean exit).

- [ ] **Step 10: Commit**

```bash
git add plug.just
git commit -m "feat: resolve JUST_PLUG_DIR in helper recipes"
```

---

## Task 3: Resolve `JUST_PLUG_DIR` in user-facing recipes

The seven recipes here already bind `root='{{justfile_directory()}}'`. Each gets the four-line resolution block appended immediately after that line, leaving the rest of the recipe untouched.

**Files:**
- Modify: `plug.just` — recipes `install`, `remove`, `update`, `verify`, `outdated`, `self-update`, `init`.

- [ ] **Step 1: Update `install`**

Find this line near the top of the `install` recipe (after `set -euo pipefail`):

```bash
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'
```

Insert the resolution snippet between them:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    jf='{{justfile()}}'
```

- [ ] **Step 2: Update `remove`**

Find:

```bash
    root='{{justfile_directory()}}'
    name='{{name}}'
```

Insert the snippet:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    name='{{name}}'
```

- [ ] **Step 3: Update `update`**

Find:

```bash
    root='{{justfile_directory()}}'
    name='{{name}}'
    jf='{{justfile()}}'
```

Insert the snippet:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    name='{{name}}'
    jf='{{justfile()}}'
```

- [ ] **Step 4: Update `verify`**

Find:

```bash
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'
    fail=0
```

Insert the snippet:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    jf='{{justfile()}}'
    fail=0
```

- [ ] **Step 5: Update `outdated`**

`outdated` currently does **not** bind `root` — it only reads via `_read-lock` (which Task 2 already updated) and calls `_source-to-url`. **No change needed** in this recipe; the relocation is fully handled by `_read-lock`.

Skip — leave `outdated` as-is. Move on to step 6.

- [ ] **Step 6: Update `self-update`**

Find:

```bash
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'
    spec='{{spec}}'
```

Insert the snippet:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    jf='{{justfile()}}'
    spec='{{spec}}'
```

- [ ] **Step 7: Update `init`**

Find:

```bash
    root='{{justfile_directory()}}'
    mkdir -p "$root/just-plug"
```

Insert the snippet:

```bash
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    mkdir -p "$root/just-plug"
```

(`mkdir -p` already creates intermediate directories, so an absolute or deeply-nested `JUST_PLUG_DIR` works without extra code.)

- [ ] **Step 8: Run the JUST_PLUG_DIR integration test — expect PASS**

The failing test from Task 1 should now pass.

Run: `bash tests/integration/test_just_plug_dir.sh`
Expected: ends with `N assertion(s) passed` and exit 0.

- [ ] **Step 9: Run the full test suite — expect PASS**

All existing tests must still pass (default behavior is byte-identical).

Run: `just -f tests/justfile test`
Expected: every `=== unit/test_*.sh ===` and `=== integration/test_*.sh ===` line is followed by `passed`, and overall exit code is 0.

- [ ] **Step 10: Commit**

```bash
git add plug.just
git commit -m "feat: resolve JUST_PLUG_DIR in user-facing recipes"
```

---

## Task 4: `init` prints resolved-root note when `JUST_PLUG_DIR` is set

When `JUST_PLUG_DIR` is set, `init`'s bootstrap message keeps the canonical `just-plug/plug.just` paths (correct when the user pastes them into a justfile sitting alongside `just-plug/`) and appends a one-line note showing where artifacts actually landed.

**Files:**
- Modify: `tests/integration/test_just_plug_dir.sh` — add an assertion.
- Modify: `plug.just` — `init` recipe.

- [ ] **Step 1: Capture init output and add a failing assertion**

In `tests/integration/test_just_plug_dir.sh`, find this section (set up in Task 1):

```bash
cd "$PROJ"
export JUST_PLUG_DIR="tools"

# init places artifacts under tools/, not at project root.
just plug init >/dev/null
```

Replace the `just plug init >/dev/null` line with:

```bash
# init places artifacts under tools/, not at project root.
init_out="$(just plug init)"
assert_contains "$init_out" "artifacts installed in $PROJ/tools" "init notes resolved root when JUST_PLUG_DIR set"
```

- [ ] **Step 2: Run the test and confirm the new assertion fails**

Run: `bash tests/integration/test_just_plug_dir.sh`
Expected: `FAIL: init notes resolved root when JUST_PLUG_DIR set` (other assertions still pass). Test exits non-zero.

- [ ] **Step 3: Update `init` to print the note**

In `plug.just`, find the end of `init`:

```just
init:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    mkdir -p "$root/just-plug"
    [ -f "$root/just-plug.deps" ] || : > "$root/just-plug.deps"
    printf '%s\n' \
        'just-plug ready. Add these two lines to your justfile if they'\''re not already there:' \
        '' \
        '    mod? plug "just-plug/plug.just"' \
        '    import? "just-plug/modules.just"' \
        '' \
        'Then install modules with:' \
        '' \
        '    just plug install github.com/<owner>/<repo>[@<ref>]'
```

Append a conditional note at the end (after the existing `printf`):

```just
init:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    mkdir -p "$root/just-plug"
    [ -f "$root/just-plug.deps" ] || : > "$root/just-plug.deps"
    printf '%s\n' \
        'just-plug ready. Add these two lines to your justfile if they'\''re not already there:' \
        '' \
        '    mod? plug "just-plug/plug.just"' \
        '    import? "just-plug/modules.just"' \
        '' \
        'Then install modules with:' \
        '' \
        '    just plug install github.com/<owner>/<repo>[@<ref>]'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        printf '\n%s\n' "Note: artifacts installed in $root (paths above are relative to a justfile that sits alongside just-plug/)."
    fi
```

- [ ] **Step 4: Run the test and confirm the new assertion passes**

Run: `bash tests/integration/test_just_plug_dir.sh`
Expected: all assertions pass, exit 0.

- [ ] **Step 5: Run the full test suite — expect PASS**

Run: `just -f tests/justfile test`
Expected: every test passes.

- [ ] **Step 6: Commit**

```bash
git add plug.just tests/integration/test_just_plug_dir.sh
git commit -m "feat: init prints resolved-root note when JUST_PLUG_DIR is set"
```

---

## Task 5: README documentation

**Files:**
- Modify: `README.md` — add "Custom artifact location" section after "File layout"; add a one-line note inside "File layout".

- [ ] **Step 1: Update the "File layout" section**

In `README.md`, find the "File layout" section (around line 83–95):

```markdown
## File layout

\`\`\`
<your project>/
├── justfile                   # your justfile (you maintain this)
├── just-plug.deps             # manifest (what you want)
├── just-plug.lock             # lockfile (what you have)
└── just-plug/
    ├── plug.just              # just-plug itself
    ├── modules.just           # auto-generated mod? lines
    ├── docker.just            # an installed module
    └── ...
\`\`\`
```

Replace it with:

````markdown
## File layout

```
<your project>/
├── justfile                   # your justfile (you maintain this)
├── just-plug.deps             # manifest (what you want)
├── just-plug.lock             # lockfile (what you have)
└── just-plug/
    ├── plug.just              # just-plug itself
    ├── modules.just           # auto-generated mod? lines
    ├── docker.just            # an installed module
    └── ...
```

These paths are rooted at the directory of your top-level justfile by default. Set [`JUST_PLUG_DIR`](#custom-artifact-location) to relocate them.
````

- [ ] **Step 2: Add the "Custom artifact location" section**

Immediately after the "File layout" section and before the "Limitations (v1)" section, insert:

````markdown
## Custom artifact location

By default, all just-plug artifacts (`just-plug.deps`, `just-plug.lock`, `just-plug/`) live next to your top-level justfile. Set `JUST_PLUG_DIR` in the environment to relocate them:

| `JUST_PLUG_DIR` | Resolved location |
|---|---|
| unset / empty | next to your top-level justfile (default) |
| absolute path | the path as-is |
| relative path | resolved relative to your top-level justfile |

Any mechanism that puts `JUST_PLUG_DIR` in the shell environment before `just` runs will work. A per-checkout tool like [mise](https://mise.jdx.dev/) is convenient:

```toml
# mise.local.toml (gitignored)
[env]
JUST_PLUG_DIR = ".local"
```

`direnv`, shell exports, and one-shot `JUST_PLUG_DIR=.local just plug install …` invocations work equivalently.

Example: tucking everything into `.local/` and loading it from a private justfile:

```
<your project>/
├── justfile                       # `import? '.local/justfile.private'`
└── .local/
    ├── justfile.private           # `mod? plug "just-plug/plug.just"`
    │                              # `import? "just-plug/modules.just"`
    ├── just-plug.deps
    ├── just-plug.lock
    └── just-plug/
        ├── plug.just
        ├── modules.just
        └── ...
```

The `mod?`/`import?` paths inside `.local/justfile.private` stay relative to that file, so they reference `just-plug/...`, not `.local/just-plug/...`.
````

- [ ] **Step 3: Sanity-read the rendered README**

Run: `grep -A 3 "Custom artifact location" README.md`
Expected: the new section heading appears with its first lines intact, no stray backticks.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document JUST_PLUG_DIR for relocating artifacts"
```

---

## Final Verification

- [ ] **Step 1: Full test suite — expect PASS**

Run: `just -f tests/justfile test`
Expected: all unit and integration tests pass, exit 0.

- [ ] **Step 2: Smoke-test the motivating use case by hand**

This catches any issue the integration test missed (e.g., `mod?`-load behavior with `import?`):

```bash
# Run this from the just-plug repo root.
REPO="$(pwd)"
TMP="$(mktemp -d)"
cd "$TMP"
mkdir -p .local/just-plug
cp "$REPO/plug.just" .local/just-plug/plug.just
cat > .local/justfile.private <<'EOF'
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
EOF
cat > justfile <<'EOF'
import? '.local/justfile.private'
EOF
export JUST_PLUG_DIR=.local
just plug init
ls .local/
# Expected output (in any order): just-plug  just-plug.deps  justfile.private
rm -rf "$TMP"
```

Expected: `.local/` contains `just-plug/`, `just-plug.deps`, and `justfile.private`. No artifacts created at the project root.

- [ ] **Step 3: Final review**

Confirm `git log --oneline -6` shows the expected sequence of commits (failing test, helpers, user-facing recipes, init note, README docs).
