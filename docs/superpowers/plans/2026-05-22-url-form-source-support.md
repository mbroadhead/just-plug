# URL-form Source Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `just plug install` to accept `https://github.com/owner/repo[.git]` and `git@github.com:owner/repo[.git]` URL forms, with a git-based fetch path so private repos work.

**Architecture:** Three accepted source forms — bare `github.com/owner/repo` (existing curl/raw fetch), HTTPS URL, and SSH URL (both new, using `git fetch --depth 1 origin <sha>` + `git cat-file`). `_parse-source` detects form by leading characters. A new `_source-to-url` helper centralizes URL derivation for `_resolve-ref`, `_fetch`, and `outdated`. Source string is stored as-typed (sans `.git` / trailing `/`); module name derivation, collision check, and lockfile shape unchanged.

**Tech Stack:** bash, just, awk, git (`ls-remote`, `init`, `remote add`, `fetch --depth 1`, `cat-file`), curl, shasum. No new dependencies.

**Spec reference:** `docs/superpowers/specs/2026-05-22-url-form-source-support.md`

---

## File Structure

Files to be created or modified:

| File | Change |
|---|---|
| `plug.just` | Modified throughout — `_parse-source`, new `_source-to-url`, `_resolve-ref`, `_fetch`, `install` (reconcile + single), `update`, `outdated`. |
| `tests/unit/test_parse.sh` | Modified — add URL form cases. |
| `tests/unit/test_source_to_url.sh` | **Created** — unit tests for the new helper. |
| `tests/integration/test_install_url.sh` | **Created** — integration test for URL-form install via `file://` fixture. |
| `tests/integration/test_resolve.sh` | Modified — pass full source (with `github.com/` prefix) to `_resolve-ref`. |
| `tests/lib/fixture.sh` | Modified — set `uploadpack.allowAnySHA1InWant` on bare fixture repos so the git-fetch path can fetch by SHA. |
| `docs/superpowers/specs/2026-05-15-just-plug-design.md` | Modified — §4 source identifier table, §8 internals add git-fetch, §11 remove "Private repos / authentication" bullet. |
| `README.md` | Modified — add URL-form usage examples. |

---

## Task 1: Add `_source-to-url` helper

**Files:**
- Modify: `plug.just` (add new recipe near `_parse-source`)
- Create: `tests/unit/test_source_to_url.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_source_to_url.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/assert.sh"

PLUG="$HERE/../../plug.just"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/justfile" <<EOF
mod? plug "$PLUG"
EOF

url() { (cd "$TMP" && just plug _source-to-url "$1"); }

# Bare form: prepend default GitHub base.
out="$(url 'github.com/foo/just-docker')"
assert_eq "https://github.com/foo/just-docker" "$out" "bare form → default GitHub URL"

# Bare form with JUST_PLUG_GIT_BASE override.
out="$(JUST_PLUG_GIT_BASE='file:///tmp/fix' url 'github.com/foo/just-docker')"
assert_eq "file:///tmp/fix/foo/just-docker" "$out" "bare form respects JUST_PLUG_GIT_BASE"

# HTTPS URL form: passed through.
out="$(url 'https://github.com/foo/just-docker')"
assert_eq "https://github.com/foo/just-docker" "$out" "https URL passed through"

# SSH URL form: passed through.
out="$(url 'git@github.com:foo/just-docker')"
assert_eq "git@github.com:foo/just-docker" "$out" "ssh URL passed through"

# file:// URL form: passed through.
out="$(url 'file:///tmp/just-fixture')"
assert_eq "file:///tmp/just-fixture" "$out" "file URL passed through"

assert_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/unit/test_source_to_url.sh`
Expected: FAIL — `error: Unknown recipe '_source-to-url'`.

- [ ] **Step 3: Add the helper recipe**

In `plug.just`, after the `_parse-source` recipe (i.e., after line 47), add:

```just
# Map a stored source string to a URL git can use.
# Bare form: prepend $JUST_PLUG_GIT_BASE (defaults to https://github.com).
# URL forms (https://, file://, ssh): returned as-is.
_source-to-url source:
    #!/usr/bin/env bash
    set -euo pipefail
    source='{{source}}'
    if [[ "$source" =~ ^https:// ]] || [[ "$source" =~ ^file:// ]] || [[ "$source" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+: ]]; then
        echo "$source"
    else
        base="${JUST_PLUG_GIT_BASE:-https://github.com}"
        repo_path="${source#github.com/}"
        echo "$base/$repo_path"
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/unit/test_source_to_url.sh`
Expected: PASS — `5 assertion(s) passed`.

- [ ] **Step 5: Verify existing tests still pass**

Run: `just -f tests/justfile test`
Expected: all unit + integration tests pass.

- [ ] **Step 6: Commit**

```bash
git add plug.just tests/unit/test_source_to_url.sh
git commit -m "feat: add _source-to-url helper for git URL derivation"
```

---

## Task 2: Accept URL forms in `_parse-source`

**Files:**
- Modify: `plug.just` lines 18-47 (`_parse-source` recipe)
- Modify: `tests/unit/test_parse.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/unit/test_parse.sh` (before `assert_exit`):

```bash
# HTTPS URL form: store as-typed sans .git, default ref main.
out="$(parse 'https://github.com/foo/just-docker')"
assert_eq "docker https://github.com/foo/just-docker main" "$out" "https url, default ref"

# HTTPS URL form with .git suffix: strip .git.
out="$(parse 'https://github.com/foo/just-docker.git')"
assert_eq "docker https://github.com/foo/just-docker main" "$out" "https url, strip .git"

# HTTPS URL form with .git and ref.
out="$(parse 'https://github.com/foo/just-docker.git@v1.2.0')"
assert_eq "docker https://github.com/foo/just-docker v1.2.0" "$out" "https url with .git and tag"

# HTTPS URL form with ref, no .git.
out="$(parse 'https://github.com/foo/just-docker@develop')"
assert_eq "docker https://github.com/foo/just-docker develop" "$out" "https url with branch ref"

# HTTPS URL with userinfo + ref — @ in userinfo must not be confused with @ref.
out="$(parse 'https://user:pass@github.com/foo/just-docker@v1.2.0')"
assert_eq "docker https://user:pass@github.com/foo/just-docker v1.2.0" "$out" "userinfo @ preserved, ref correctly split"

# SSH URL form: store as-typed sans .git, default ref main.
out="$(parse 'git@github.com:foo/just-docker')"
assert_eq "docker git@github.com:foo/just-docker main" "$out" "ssh url, default ref"

# SSH URL form with .git: strip .git.
out="$(parse 'git@github.com:foo/just-docker.git')"
assert_eq "docker git@github.com:foo/just-docker main" "$out" "ssh url, strip .git"

# SSH URL form with .git and ref.
out="$(parse 'git@github.com:foo/just-docker.git@v1.2.0')"
assert_eq "docker git@github.com:foo/just-docker v1.2.0" "$out" "ssh url with .git and tag"

# SSH URL form with ref, no .git.
out="$(parse 'git@github.com:foo/just-docker@develop')"
assert_eq "docker git@github.com:foo/just-docker develop" "$out" "ssh url with branch ref"

# file:// URL form.
out="$(parse 'file:///tmp/just-fixture')"
assert_eq "fixture file:///tmp/just-fixture main" "$out" "file URL form"

# Invalid HTTPS URL: missing repo path segment.
if parse 'https://github.com/foo' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: https url without repo segment should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi

# Invalid SSH URL: missing repo path.
if parse 'git@github.com:foo' 2>/dev/null; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: ssh url without repo segment should be rejected"
else
    ASSERT_OK=$((ASSERT_OK + 1))
fi
```

- [ ] **Step 2: Run test to verify new cases fail**

Run: `bash tests/unit/test_parse.sh`
Expected: FAIL — multiple cases fail because `_parse-source` rejects non-bare forms.

- [ ] **Step 3: Replace `_parse-source` in `plug.just`**

Replace the entire current `_parse-source` recipe (lines 15-47) with:

```just
# Parse a source identifier. Accepted forms (each may have an optional @<ref> suffix):
#   github.com/<owner>/<repo>            (bare — fetched via raw.githubusercontent.com)
#   https://<host>/<path>/<repo>[.git]   (HTTPS URL — fetched via git)
#   <user>@<host>:<path>/<repo>[.git]    (SSH URL — fetched via git)
#   file:///<path>/<repo>[.git]          (file URL — fetched via git, mainly for tests)
#
# Output (stdout): "<name> <source> <ref>" — three space-separated fields.
# `source` is the form as typed, with trailing .git and trailing / stripped.
# Exits non-zero on invalid input.
_parse-source spec:
    #!/usr/bin/env bash
    set -euo pipefail
    spec='{{spec}}'

    if [[ "$spec" =~ ^https:// ]] || [[ "$spec" =~ ^file:// ]]; then
        # HTTPS/file URL form: <scheme>://<authority>/<path>[@<ref>]
        scheme="${spec%%://*}://"
        rest="${spec#*://}"
        if [[ "$rest" != */* ]]; then
            echo "error: URL must have a path component: $spec" >&2
            exit 1
        fi
        authority="${rest%%/*}"
        path_part="${rest#*/}"
        # Split @<ref> from the path only — preserves any @ in userinfo (authority).
        if [[ "$path_part" == *"@"* ]]; then
            ref="${path_part##*@}"
            path_part="${path_part%@*}"
        else
            ref="main"
        fi
        # Strip trailing .git and trailing /.
        path_part="${path_part%.git}"
        path_part="${path_part%/}"
        if [ -z "$path_part" ] || [[ "$path_part" != */* ]]; then
            echo "error: URL must have an owner/repo path: $spec" >&2
            exit 1
        fi
        source="${scheme}${authority}/${path_part}"
        repo="${path_part##*/}"
    elif [[ "$spec" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+: ]]; then
        # SSH URL form: <user>@<host>:<path>[@<ref>]
        userhost="${spec%%:*}"
        path_part="${spec#*:}"
        if [[ "$path_part" == *"@"* ]]; then
            ref="${path_part##*@}"
            path_part="${path_part%@*}"
        else
            ref="main"
        fi
        path_part="${path_part%.git}"
        path_part="${path_part%/}"
        if [ -z "$path_part" ] || [[ "$path_part" != */* ]]; then
            echo "error: SSH URL must have an owner/repo path: $spec" >&2
            exit 1
        fi
        source="${userhost}:${path_part}"
        repo="${path_part##*/}"
    else
        # Bare form: github.com/<owner>/<repo>[@<ref>]
        if [[ "$spec" == *"@"* ]]; then
            ref="${spec##*@}"
            source="${spec%@*}"
        else
            ref="main"
            source="$spec"
        fi
        if [[ ! "$source" =~ ^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            echo "error: source must look like 'github.com/<owner>/<repo>', got: $source" >&2
            exit 1
        fi
        repo="${source##*/}"
    fi

    # Derive name: repo basename minus leading 'just-'.
    name="${repo#just-}"
    if [ -z "$name" ]; then
        echo "error: derived module name is empty for source $source" >&2
        exit 1
    fi

    echo "$name $source $ref"
```

- [ ] **Step 4: Run unit tests to verify all parse cases pass**

Run: `bash tests/unit/test_parse.sh`
Expected: PASS — all assertions (existing bare + new URL cases) pass.

- [ ] **Step 5: Run full test suite — install/reconcile/etc. should still pass against bare form**

Run: `just -f tests/justfile test`
Expected: all tests pass. URL forms not yet supported end-to-end (later tasks), but bare-form regression is the check here.

- [ ] **Step 6: Commit**

```bash
git add plug.just tests/unit/test_parse.sh
git commit -m "feat: accept https/ssh/file URL forms in _parse-source"
```

---

## Task 3: Switch `_resolve-ref` to take full source string

**Files:**
- Modify: `plug.just` lines 53-78 (`_resolve-ref` recipe)
- Modify: `plug.just` line ~227 (install reconcile — stop stripping `github.com/`)
- Modify: `plug.just` lines ~282-284 (install single mode — stop stripping)
- Modify: `plug.just` lines ~343-344 (update — stop stripping)
- Modify: `tests/integration/test_resolve.sh` — pass `github.com/demo/just-docker` instead of `demo/just-docker`

- [ ] **Step 1: Update `test_resolve.sh` to pass full bare source**

Change every call from `just plug _resolve-ref demo/just-docker <ref>` to `just plug _resolve-ref github.com/demo/just-docker <ref>`. There are five such calls (lines 25, 29, 33, 37, 41).

The expected outputs are unchanged (SHAs and pass-through behavior).

- [ ] **Step 2: Run test_resolve.sh to verify it now fails**

Run: `bash tests/integration/test_resolve.sh`
Expected: FAIL — `_resolve-ref` builds the URL by prepending `JUST_PLUG_GIT_BASE/$source` so passing `github.com/demo/just-docker` produces `file:///fixture/git/github.com/demo/just-docker` which doesn't exist.

- [ ] **Step 3: Update `_resolve-ref` to use `_source-to-url`**

Replace the current `_resolve-ref` body (lines 53-78) with:

```just
# Resolve a ref to a 40-char commit SHA.
# Args: <source> <ref>  (source is the full form as stored in deps/lock)
# - If <ref> matches ^[0-9a-f]{7,40}$, pass through unchanged.
# - Otherwise, git ls-remote against the URL derived from <source>.
_resolve-ref source ref:
    #!/usr/bin/env bash
    set -euo pipefail
    source='{{source}}'
    ref='{{ref}}'

    if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "$ref"
        exit 0
    fi

    url="$(just --justfile '{{justfile()}}' plug _source-to-url "$source")"

    sha="$(git ls-remote "$url" "refs/tags/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -z "$sha" ]; then
        sha="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
    fi

    if [ -z "$sha" ]; then
        echo "error: could not resolve ref '$ref' in $source" >&2
        exit 1
    fi

    echo "$sha"
```

- [ ] **Step 4: Update all callers to pass the full source (no more `${source#github.com/}` stripping)**

In `plug.just`, find and update three call sites:

**4a.** In `install` reconcile mode (currently around line 226-227):

```bash
# OLD:
# _resolve-ref expects "<owner>/<repo>", not "github.com/<owner>/<repo>".
repo_path="${source#github.com/}"
sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"
```

Replace with:

```bash
sha="$(just --justfile "$jf" plug _resolve-ref "$source" "$ref")"
```

**4b.** In `install` single mode (currently around line 282-284):

```bash
# OLD:
# Resolve ref → SHA.
# _resolve-ref expects "<owner>/<repo>", not "github.com/<owner>/<repo>".
repo_path="${source#github.com/}"
sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"
```

Replace with:

```bash
# Resolve ref → SHA.
sha="$(just --justfile "$jf" plug _resolve-ref "$source" "$ref")"
```

**4c.** In `update` recipe's `update_one` function (currently around line 343-344):

```bash
# OLD:
local repo_path="${src#github.com/}"
new_sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"
```

Replace with:

```bash
new_sha="$(just --justfile "$jf" plug _resolve-ref "$src" "$ref")"
```

- [ ] **Step 5: Run full test suite**

Run: `just -f tests/justfile test`
Expected: all tests pass. `test_resolve.sh` now exercises the new full-source contract.

- [ ] **Step 6: Commit**

```bash
git add plug.just tests/integration/test_resolve.sh
git commit -m "refactor: _resolve-ref takes full source, uses _source-to-url"
```

---

## Task 4: Extend `install` single-mode inline parser for URL forms

**Files:**
- Modify: `plug.just` lines ~252-269 (single-install inline parse block)

The single-install inline parse currently rejects anything that isn't `github.com/<owner>/<repo>`. Replicate the three-form logic from `_parse-source` inline.

- [ ] **Step 1: Replace the inline parse block in `install` single mode**

Find this block in `plug.just` (currently around line 252):

```bash
    # Single-install mode (existing behavior).
    # Parse inline (mirrors _parse-source logic) to avoid sub-just cwd issues.
    if [[ "$spec" == *"@"* ]]; then
        ref="${spec##*@}"
        source="${spec%@*}"
    else
        ref="main"
        source="$spec"
    fi
    if [[ ! "$source" =~ ^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        echo "error: source must look like 'github.com/<owner>/<repo>', got: $source" >&2
        exit 1
    fi
    repo="${source##*/}"
    name="${repo#just-}"
    if [ -z "$name" ]; then
        echo "error: derived module name is empty for source $source" >&2
        exit 1
    fi
```

Replace with:

```bash
    # Single-install mode.
    # Parse inline (mirrors _parse-source logic) to avoid sub-just cwd issues.
    if [[ "$spec" =~ ^https:// ]] || [[ "$spec" =~ ^file:// ]]; then
        scheme="${spec%%://*}://"
        rest="${spec#*://}"
        if [[ "$rest" != */* ]]; then
            echo "error: URL must have a path component: $spec" >&2
            exit 1
        fi
        authority="${rest%%/*}"
        path_part="${rest#*/}"
        if [[ "$path_part" == *"@"* ]]; then
            ref="${path_part##*@}"
            path_part="${path_part%@*}"
        else
            ref="main"
        fi
        path_part="${path_part%.git}"
        path_part="${path_part%/}"
        if [ -z "$path_part" ] || [[ "$path_part" != */* ]]; then
            echo "error: URL must have an owner/repo path: $spec" >&2
            exit 1
        fi
        source="${scheme}${authority}/${path_part}"
        repo="${path_part##*/}"
    elif [[ "$spec" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+: ]]; then
        userhost="${spec%%:*}"
        path_part="${spec#*:}"
        if [[ "$path_part" == *"@"* ]]; then
            ref="${path_part##*@}"
            path_part="${path_part%@*}"
        else
            ref="main"
        fi
        path_part="${path_part%.git}"
        path_part="${path_part%/}"
        if [ -z "$path_part" ] || [[ "$path_part" != */* ]]; then
            echo "error: SSH URL must have an owner/repo path: $spec" >&2
            exit 1
        fi
        source="${userhost}:${path_part}"
        repo="${path_part##*/}"
    else
        if [[ "$spec" == *"@"* ]]; then
            ref="${spec##*@}"
            source="${spec%@*}"
        else
            ref="main"
            source="$spec"
        fi
        if [[ ! "$source" =~ ^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            echo "error: source must look like 'github.com/<owner>/<repo>', got: $source" >&2
            exit 1
        fi
        repo="${source##*/}"
    fi
    name="${repo#just-}"
    if [ -z "$name" ]; then
        echo "error: derived module name is empty for source $source" >&2
        exit 1
    fi
```

- [ ] **Step 2: Run full test suite**

Run: `just -f tests/justfile test`
Expected: all tests pass. The new branch isn't exercised end-to-end yet (no URL-form integration test) but bare-form behavior must not regress.

- [ ] **Step 3: Commit**

```bash
git add plug.just
git commit -m "feat: install accepts URL forms in single-mode inline parser"
```

---

## Task 5: Switch `outdated` to use `_source-to-url`

**Files:**
- Modify: `plug.just` lines ~399-442 (`outdated` recipe)

- [ ] **Step 1: Update `outdated` body**

In the `outdated` recipe, replace the inline base/repo_path URL construction. Current (around line 404 and line 411-412):

```bash
    base="${JUST_PLUG_GIT_BASE:-https://github.com}"
    while read -r name source ref locked_sha hash; do
        ...
        repo_path="${source#github.com/}"
        url="$base/$repo_path"
```

Replace those lines with:

```bash
    jf='{{justfile()}}'
    while read -r name source ref locked_sha hash; do
        ...
        url="$(just --justfile "$jf" plug _source-to-url "$source")"
```

(Remove the `base=` line entirely; remove the `repo_path=` line; replace the `url=` line.)

- [ ] **Step 2: Run full test suite**

Run: `just -f tests/justfile test`
Expected: all tests pass, including `tests/integration/test_outdated.sh`.

- [ ] **Step 3: Commit**

```bash
git add plug.just
git commit -m "refactor: outdated uses _source-to-url"
```

---

## Task 6: Allow SHA fetch on fixture bare repos

**Files:**
- Modify: `tests/lib/fixture.sh` (in `fixture_add_module`, after the bare-clone step)

`git fetch --depth 1 origin <sha>` requires the server to allow SHA-targeted fetches. GitHub has `uploadpack.allowReachableSHA1InWant` enabled platform-wide; for local bare-repo fixtures we need to enable it explicitly.

- [ ] **Step 1: Add the config line in `fixture_add_module`**

In `tests/lib/fixture.sh`, locate the block in `fixture_add_module` that runs `git clone -q --bare . "$bare"` (currently line 78). Immediately after the closing `)` of the subshell (around line 79), add:

```bash
    # Allow `git fetch --depth 1 origin <sha>` against the bare repo (mirrors
    # GitHub's platform-wide uploadpack.allowReachableSHA1InWant default).
    git -C "$bare" config uploadpack.allowAnySHA1InWant true
```

- [ ] **Step 2: Run full test suite to confirm no regression**

Run: `just -f tests/justfile test`
Expected: all tests pass. (This change is preparation for Task 7; no existing test exercises the SHA-fetch path yet.)

- [ ] **Step 3: Commit**

```bash
git add tests/lib/fixture.sh
git commit -m "test: fixture bare repos allow fetch by SHA"
```

---

## Task 7: Add git-fetch branch in `_fetch` + integration test

**Files:**
- Modify: `plug.just` lines ~83-107 (`_fetch` recipe)
- Create: `tests/integration/test_install_url.sh`

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration/test_install_url.sh`:

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

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/justfile" <<EOF
mod? plug "$PLUG"
EOF

CONTENT='show:
    @echo hi from url-form
'
fixture_add_module "demo/just-widget" "widget.just" "v1.0.0" "$CONTENT"

# Build a file:// URL pointing at the fixture bare repo.
URL="file://${_FIXTURE_GIT_ROOT}/demo/just-widget"

cd "$PROJ"
just plug init >/dev/null

# Install via the URL form pinned to a tag — exercises the git-fetch path.
just plug install "${URL}@v1.0.0"

assert_file_exists "$PROJ/just-plug/widget.just" "url-form install creates module file"
if diff -q <(printf '%s' "$CONTENT") just-plug/widget.just >/dev/null 2>&1; then
    ASSERT_OK=$((ASSERT_OK + 1))
else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "FAIL: url-form module content mismatch"
fi

deps="$(cat just-plug.deps)"
assert_contains "$deps" "widget $URL v1.0.0" "deps records the URL form as typed"

lock="$(cat just-plug.lock)"
assert_contains "$lock" "widget $URL v1.0.0" "lock records the URL form"

mods="$(cat just-plug/modules.just)"
assert_contains "$mods" 'mod? widget "widget.just"' "modules.just regenerated"

# Install with explicit .git suffix — must normalize to the same source.
fixture_add_module "demo/just-gadget" "gadget.just" "v0.1.0" 'go:
    @echo go
'
GADGET_URL="file://${_FIXTURE_GIT_ROOT}/demo/just-gadget"
just plug install "${GADGET_URL}.git@v0.1.0"
deps="$(cat just-plug.deps)"
assert_contains "$deps" "gadget $GADGET_URL v0.1.0" ".git suffix stripped on store"

# Default ref (no @ref) installs from main.
fixture_add_module "demo/just-mainline" "mainline.just" "v0.0.1" 'hi:
    @echo main
'
MAIN_URL="file://${_FIXTURE_GIT_ROOT}/demo/just-mainline"
just plug install "$MAIN_URL"
deps_main="$(awk '$1 == "mainline"' just-plug.deps)"
assert_contains "$deps_main" "main" "default ref is main for URL form"

assert_exit
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `bash tests/integration/test_install_url.sh`
Expected: FAIL — `_fetch` still uses the curl/raw path and gets a bogus URL like `http://127.0.0.1:.../file:///.../...`.

- [ ] **Step 3: Replace `_fetch` with form-aware logic**

Replace the entire current `_fetch` recipe (lines 80-107) with:

```just
# Fetch <filename> at <sha> from <source> to <dest>.
# Writes via tempfile + atomic mv; on failure, <dest> is untouched.
# Outputs the sha256 of the fetched content on success.
#
# Bare github.com/<owner>/<repo> sources go through raw.githubusercontent.com.
# URL-form sources go through git: shallow init, fetch --depth 1 <sha>, cat-file.
_fetch source sha filename dest:
    #!/usr/bin/env bash
    set -euo pipefail
    source='{{source}}'
    sha='{{sha}}'
    filename='{{filename}}'
    dest='{{dest}}'

    tmp="$(mktemp "${dest}.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    if [[ "$source" =~ ^https:// ]] || [[ "$source" =~ ^file:// ]] || [[ "$source" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+: ]]; then
        # URL form: shallow git fetch by SHA, extract one file.
        url="$(just --justfile '{{justfile()}}' plug _source-to-url "$source")"
        work="$(mktemp -d)"
        trap 'rm -f "$tmp"; rm -rf "$work"' EXIT
        git -C "$work" init -q
        git -C "$work" remote add origin "$url"
        if ! git -C "$work" fetch --depth 1 -q origin "$sha"; then
            echo "error: git fetch failed: $url @ $sha" >&2
            exit 1
        fi
        if ! git -C "$work" cat-file -p "$sha:$filename" > "$tmp"; then
            echo "error: $filename not found at $sha in $url" >&2
            exit 1
        fi
    else
        # Bare github.com form: raw HTTP fetch.
        base="${JUST_PLUG_RAW_BASE:-https://raw.githubusercontent.com}"
        repo_path="${source#github.com/}"
        url="$base/$repo_path/$sha/$filename"
        if ! curl -fsSL --max-time 60 -o "$tmp" "$url"; then
            echo "error: fetch failed: $url" >&2
            exit 1
        fi
    fi

    hash="$(shasum -a 256 < "$tmp" | awk '{print $1}')"
    mv "$tmp" "$dest"
    trap - EXIT
    echo "$hash"
```

- [ ] **Step 4: Run the integration test to confirm it passes**

Run: `bash tests/integration/test_install_url.sh`
Expected: PASS — all assertions pass; the URL form installs via git and lockfile contains the URL.

- [ ] **Step 5: Run full test suite to confirm no regression**

Run: `just -f tests/justfile test`
Expected: all unit + integration tests pass.

- [ ] **Step 6: Commit**

```bash
git add plug.just tests/integration/test_install_url.sh
git commit -m "feat: _fetch routes URL-form sources through git fetch + cat-file"
```

---

## Task 8: Update v1 design spec

**Files:**
- Modify: `docs/superpowers/specs/2026-05-15-just-plug-design.md`

Reconcile the v1 design doc with the new behavior. Three edits.

- [ ] **Step 1: Update §4 "Source identifier"**

Find the bullet (around line 49):

```markdown
- **Source identifier:** `github.com/<owner>/<repo>` (no scheme, no `.git`, no file suffix). GitHub-only for v1.
```

Replace with:

```markdown
- **Source identifier:** one of three forms (each may carry an optional `@<ref>` suffix):
    - `github.com/<owner>/<repo>` — bare GitHub identifier; fetched via `raw.githubusercontent.com`.
    - `https://<host>/<path>/<repo>[.git]` — HTTPS URL; fetched via `git fetch --depth 1`.
    - `<user>@<host>:<path>/<repo>[.git]` — SSH URL; fetched via `git fetch --depth 1`, suitable for private repos via SSH key auth.

  Bare form is github.com-only. URL forms route through `git` and so respect the user's git auth (SSH keys, credential helpers); they work with any host `git` understands. Trailing `.git` and trailing `/` are stripped at storage time.
```

- [ ] **Step 2: Update §8 "Internals" — replace the HTTP fetch line**

Find (around line 134):

```markdown
- **HTTP fetch:** `curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<name>.just`
- **Ref resolution:** `git ls-remote https://github.com/<owner>/<repo> <ref>`. A ref matching `^[0-9a-f]{7,40}$` is treated as a commit SHA and passed through unchanged (no remote round-trip).
```

Replace with:

```markdown
- **Bare-form fetch:** `curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<name>.just`
- **URL-form fetch:** `git init` a tempdir, `git remote add origin <url>`, `git fetch --depth 1 origin <sha>`, `git cat-file -p <sha>:<name>.just`. Relies on GitHub's platform-wide `uploadpack.allowReachableSHA1InWant`; other hosts must enable the same option (test fixtures set `uploadpack.allowAnySHA1InWant`).
- **Ref resolution:** `git ls-remote <url> <ref>`, where `<url>` is derived per source form (bare → `https://github.com/<owner>/<repo>`; URL forms used as-is). A ref matching `^[0-9a-f]{7,40}$` is treated as a commit SHA and passed through unchanged.
```

- [ ] **Step 3: Update §11 "Out of scope for v1" — remove the private repos bullet**

Find (around line 172):

```markdown
- Private repos / authentication. (HTTPS public only; user's git config and `.netrc` may make private repos accidentally work, but it's not designed for or tested.)
```

Delete this bullet entirely. The other out-of-scope items (non-GitHub, semver, transitive deps, multi-module, self-update, cross-project caching) stay.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-15-just-plug-design.md
git commit -m "docs: reconcile v1 design with URL-form/private-repo support"
```

---

## Task 9: Update README with URL-form usage

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Extend the Usage section**

In `README.md`, find the Usage block (around line 24-28):

```sh
# Install a module from GitHub. Default ref is `main`.
just plug install github.com/foo/just-docker
just plug install github.com/foo/just-docker@v1.2.0
just plug install github.com/foo/just-docker@develop
just plug install github.com/foo/just-docker@abc1234
```

Replace with:

```sh
# Install a module from GitHub. Default ref is `main`.
just plug install github.com/foo/just-docker
just plug install github.com/foo/just-docker@v1.2.0
just plug install github.com/foo/just-docker@develop
just plug install github.com/foo/just-docker@abc1234

# URL forms — useful for paste-from-`git remote -v` and required for private repos.
just plug install https://github.com/foo/just-docker.git
just plug install git@github.com:foo/just-docker.git@v1.2.0
```

- [ ] **Step 2: Update "Limitations (v1)" section to remove the private-repo line**

In `README.md`, find the Limitations block (around line 86-93). Currently:

```markdown
## Limitations (v1)

- GitHub-only. No GitLab/Codeberg/raw URLs.
- One module per repo.
- No transitive dependencies.
- No semver ranges — pin to a tag, branch, or SHA.
- `outdated` for tag pins uses `sort -V` and may misbehave on unusual tag formats.
- Repos whose default branch isn't `main` require an explicit `@master` (or whatever) ref.
```

Replace the first bullet:

```markdown
- GitHub-only for the bare `github.com/owner/repo` form. URL forms (HTTPS and SSH) work for any host `git` understands, but only GitHub is exercised in tests.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document URL-form install in README"
```

---

## Task 10: Final verification

- [ ] **Step 1: Run the entire test suite**

Run: `just -f tests/justfile test`
Expected: all unit and integration tests pass.

- [ ] **Step 2: Hand-spot-check a URL-form install**

In a scratch dir:

```bash
mkdir /tmp/url-check && cd /tmp/url-check
mkdir just-plug
cp /Users/mitch/src/pmtbox/just-plug/plug.just just-plug/
cat > justfile <<'EOF'
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
EOF
just plug init
# Public repo via URL form to confirm GitHub HTTPS git path works end-to-end.
just plug install https://github.com/casey/just.git@master  # any real repo with a .just file at root is fine; or skip this step if no convenient public test target exists
just plug list
just plug verify
```

Expected: install succeeds (if the chosen repo has a `<name>.just` at root), `plug list` shows it, `plug verify` reports `ok`. If your public test target lacks a matching `<name>.just`, swap for one that has one (e.g., a known just-plug-template-based repo) or skip this manual check.

- [ ] **Step 3: (Optional) Smoke-test against a real private repo**

If you have SSH access to a private GitHub repo with a `<name>.just` at root:

```bash
just plug install git@github.com:Paymentbox-com/just-pbx-wt.git
just plug list
just plug verify
```

Expected: install succeeds, `plug list` shows it, `plug verify` reports `ok`. This validates the SSH auth path end-to-end.
