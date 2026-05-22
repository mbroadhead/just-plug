# just-plug — a package manager for justfile modules.
# Bootstrap: curl -fsSL https://raw.githubusercontent.com/<owner>/just-plug/main/plug.just > just-plug/plug.just
#
# All recipes anchor paths to justfile_directory(), which resolves to the
# user's project root (the directory containing the justfile that imported this module).

# Print plug-internal paths. Used by tests; harmless for users.
_paths:
    @echo "ROOT={{justfile_directory()}}"
    @echo "DEPS={{justfile_directory()}}/just-plug.deps"
    @echo "LOCK={{justfile_directory()}}/just-plug.lock"
    @echo "PLUGDIR={{justfile_directory()}}/just-plug"
    @echo "MODSFILE={{justfile_directory()}}/just-plug/modules.just"

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

# Resolve a ref to a 40-char commit SHA.
# Args: <source> <ref>
# - If <ref> matches ^[0-9a-f]{7,40}$, pass through unchanged.
# - Otherwise, git ls-remote against $JUST_PLUG_GIT_BASE/<source>.
_resolve-ref source ref:
    #!/usr/bin/env bash
    set -euo pipefail
    source='{{source}}'
    ref='{{ref}}'

    if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "$ref"
        exit 0
    fi

    base="${JUST_PLUG_GIT_BASE:-https://github.com}"
    url="$base/$source"

    # Try tag first, then branch. ls-remote prints lines like "<sha>\t<full-ref>".
    sha="$(git ls-remote "$url" "refs/tags/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -z "$sha" ]; then
        sha="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
    fi

    if [ -z "$sha" ]; then
        echo "error: could not resolve ref '$ref' in $source" >&2
        exit 1
    fi

    echo "$sha"

# Fetch <filename> at <sha> from <source> to <dest>.
# Writes via tempfile + atomic mv; on failure, <dest> is untouched.
# Outputs the sha256 of the fetched content on success.
_fetch source sha filename dest:
    #!/usr/bin/env bash
    set -euo pipefail
    source='{{source}}'
    sha='{{sha}}'
    filename='{{filename}}'
    dest='{{dest}}'

    base="${JUST_PLUG_RAW_BASE:-https://raw.githubusercontent.com}"
    # source is "github.com/<owner>/<repo>"; strip the "github.com/" prefix for the raw URL.
    repo_path="${source#github.com/}"
    url="$base/$repo_path/$sha/$filename"

    tmp="$(mktemp "${dest}.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    if ! curl -fsSL --max-time 60 -o "$tmp" "$url"; then
        echo "error: fetch failed: $url" >&2
        exit 1
    fi

    hash="$(shasum -a 256 < "$tmp" | awk '{print $1}')"
    mv "$tmp" "$dest"
    trap - EXIT
    echo "$hash"

# Read just-plug.deps, emitting "<name> <source> <ref>" per line.
# Skips blank lines and lines starting with #. Missing file → no output.
_read-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.deps'
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3}' "$f"

# Read just-plug.lock, emitting "<name> <source> <ref> <sha> <hash>" per line.
_read-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.lock'
    if [ ! -f "$f" ]; then exit 0; fi
    awk 'NF && $1 !~ /^#/ {print $1, $2, $3, $4, $5}' "$f"

# Insert or update a deps entry by name.
# Args: <name> <source> <ref>
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

# Remove a deps entry by name.
_remove-dep name:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.deps'
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"

# Insert or update a lock entry by name.
# Args: <name> <source> <ref> <sha> <hash>
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

# Remove a lock entry by name.
_remove-lock name:
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{justfile_directory()}}/just-plug.lock'
    name='{{name}}'
    if [ ! -f "$f" ]; then exit 0; fi
    tmp="$(mktemp "${f}.XXXXXX")"
    awk -v n="$name" 'NF && $1 !~ /^#/ && $1 != n {print $1, $2, $3, $4, $5}' "$f" | sort > "$tmp"
    mv "$tmp" "$f"

# Regenerate just-plug/modules.just from just-plug.lock.
# One `mod? <name> "<name>.just"` line per locked entry, sorted.
# Paths are relative to modules.just's own location (just-plug/), so just-plug/
# resolves them correctly when `import?`ed from a parent justfile.
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

# Install a single module, or (no args) reconcile state against just-plug.deps.
# Usage: just plug install [github.com/<owner>/<repo>[@<ref>]]
install spec="":
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'

    spec='{{spec}}'

    if [ -z "$spec" ]; then
        # Reconcile mode.
        # 1. For every dep, install at lock SHA if present, else freshly resolve.
        # 2. Remove any installed module not in deps.
        mkdir -p "$root/just-plug"
        deps_names="$(just --justfile "$jf" plug _read-deps | awk '{print $1}' | sort -u)"
        lock_names="$(just --justfile "$jf" plug _read-lock | awk '{print $1}' | sort -u)"

        # Install / refresh every dep entry.
        while read -r name source ref; do
            [ -z "$name" ] && continue
            locked_line="$(just --justfile "$jf" plug _read-lock | awk -v n="$name" -v s="$source" -v r="$ref" '$1==n && $2==s && $3==r {print}')"
            if [ -n "$locked_line" ]; then
                sha="$(echo "$locked_line" | awk '{print $4}')"
                hash_recorded="$(echo "$locked_line" | awk '{print $5}')"
            else
                # _resolve-ref expects "<owner>/<repo>", not "github.com/<owner>/<repo>".
                repo_path="${source#github.com/}"
                sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"
                hash_recorded=""
            fi
            # If file already present and lock has hash, only re-fetch when missing.
            if [ -f "$root/just-plug/$name.just" ] && [ -n "$hash_recorded" ]; then
                : # leave it
            else
                hash_recorded="$(just --justfile "$jf" plug _fetch "$source" "$sha" "$name.just" "$root/just-plug/$name.just")"
            fi
            just --justfile "$jf" plug _upsert-lock "$name" "$source" "$ref" "$sha" "$hash_recorded"
        done < <(just --justfile "$jf" plug _read-deps)

        # Orphans: anything in lock_names not in deps_names → remove.
        for name in $lock_names; do
            if ! echo "$deps_names" | grep -qxF "$name"; then
                rm -f "$root/just-plug/$name.just"
                just --justfile "$jf" plug _remove-lock "$name"
            fi
        done

        just --justfile "$jf" plug _gen-modules
        exit 0
    fi

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

    # Collision check: same name, different source already installed?
    if [ -f "$root/just-plug.lock" ]; then
        existing_src="$(awk -v n="$name" '$1 == n {print $2}' "$root/just-plug.lock")"
        if [ -n "$existing_src" ] && [ "$existing_src" != "$source" ]; then
            echo "error: module '$name' is already installed from $existing_src" >&2
            echo "       remove it first with: just plug remove $name" >&2
            exit 1
        fi
    fi

    # Resolve ref → SHA.
    # _resolve-ref expects "<owner>/<repo>", not "github.com/<owner>/<repo>".
    repo_path="${source#github.com/}"
    sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"

    # Fetch into just-plug/<name>.just (atomic).
    mkdir -p "$root/just-plug"
    hash="$(just --justfile "$jf" plug _fetch "$source" "$sha" "$name.just" "$root/just-plug/$name.just")"

    # Update state.
    just --justfile "$jf" plug _upsert-dep "$name" "$source" "$ref"
    just --justfile "$jf" plug _upsert-lock "$name" "$source" "$ref" "$sha" "$hash"
    just --justfile "$jf" plug _gen-modules

    echo "installed $name @ $ref ($sha)"

# Remove an installed module.
remove name:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    name='{{name}}'
    jf='{{justfile()}}'
    file="$root/just-plug/$name.just"
    installed=0
    if [ -f "$file" ]; then
        rm -f "$file"
        installed=1
    fi
    just --justfile "$jf" plug _remove-dep "$name"
    just --justfile "$jf" plug _remove-lock "$name"
    just --justfile "$jf" plug _gen-modules
    if [ "$installed" -eq 1 ]; then
        echo "removed $name"
    else
        echo "notice: $name was not installed" >&2
    fi

# List installed modules with their pinned ref, resolved SHA, and source.
list:
    #!/usr/bin/env bash
    set -euo pipefail
    jf='{{justfile()}}'
    lock_lines="$(just --justfile "$jf" plug _read-lock)"
    if [ -z "$lock_lines" ]; then
        echo "no modules installed"
        exit 0
    fi
    printf '%-20s %-12s %-10s %s\n' NAME REF SHA SOURCE
    echo "$lock_lines" | awk '{printf "%-20s %-12s %-10s %s\n", $1, $3, substr($4,1,10), $2}'

# Re-resolve and refetch a module (or all modules if no name).
update name="":
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    name='{{name}}'
    jf='{{justfile()}}'

    update_one() {
        local n="$1" src="$2" ref="$3"
        local new_sha old_sha old_hash new_hash
        local repo_path="${src#github.com/}"
        new_sha="$(just --justfile "$jf" plug _resolve-ref "$repo_path" "$ref")"
        old_sha="$(awk -v n="$n" '$1==n {print $4}' "$root/just-plug.lock" 2>/dev/null || true)"
        old_hash="$(awk -v n="$n" '$1==n {print $5}' "$root/just-plug.lock" 2>/dev/null || true)"
        if [ "$new_sha" = "$old_sha" ] && [ -f "$root/just-plug/$n.just" ]; then
            return 0  # no change
        fi
        new_hash="$(just --justfile "$jf" plug _fetch "$src" "$new_sha" "$n.just" "$root/just-plug/$n.just")"
        just --justfile "$jf" plug _upsert-lock "$n" "$src" "$ref" "$new_sha" "$new_hash"
        echo "updated $n: $old_sha → $new_sha"
    }

    if [ -n "$name" ]; then
        line="$(just --justfile "$jf" plug _read-deps | awk -v n="$name" '$1==n')"
        if [ -z "$line" ]; then
            echo "error: $name is not declared in just-plug.deps" >&2
            exit 1
        fi
        read -r n src ref <<<"$line"
        update_one "$n" "$src" "$ref"
    else
        while read -r n src ref; do
            [ -z "$n" ] && continue
            update_one "$n" "$src" "$ref"
        done < <(just --justfile "$jf" plug _read-deps)
    fi

    just --justfile "$jf" plug _gen-modules

# Verify installed module files match the lockfile hashes. Read-only. Non-zero on mismatch.
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'
    fail=0
    while read -r name source ref sha hash; do
        [ -z "$name" ] && continue
        file="$root/just-plug/$name.just"
        if [ ! -f "$file" ]; then
            echo "MISSING: $name ($file)"
            fail=1
            continue
        fi
        actual="$(shasum -a 256 < "$file" | awk '{print $1}')"
        if [ "$actual" != "$hash" ]; then
            echo "MISMATCH: $name (expected $hash, got $actual)"
            fail=1
        fi
    done < <(just --justfile "$jf" plug _read-lock)
    if [ "$fail" -eq 0 ]; then
        echo "ok"
    fi
    exit "$fail"

# Report modules whose pinned ref has moved upstream. Read-only.
outdated:
    #!/usr/bin/env bash
    set -euo pipefail
    jf='{{justfile()}}'
    found=0
    base="${JUST_PLUG_GIT_BASE:-https://github.com}"
    while read -r name source ref locked_sha hash; do
        [ -z "$name" ] && continue
        # SHA pin: never outdated.
        if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
            continue
        fi
        repo_path="${source#github.com/}"
        url="$base/$repo_path"
        # Try tag.
        sha="$(git ls-remote "$url" "refs/tags/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
        if [ -n "$sha" ]; then
            # Tag pin: look for newer tags by version-sort.
            newest="$(git ls-remote --tags "$url" 2>/dev/null \
                | awk '{print $2}' \
                | sed 's|refs/tags/||' \
                | grep -v '\^{}' \
                | sort -V \
                | tail -1)"
            if [ -n "$newest" ] && [ "$newest" != "$ref" ]; then
                # Only report if newest sorts strictly after ref.
                latest_sorted="$(printf '%s\n%s\n' "$ref" "$newest" | sort -V | tail -1)"
                if [ "$latest_sorted" = "$newest" ] && [ "$newest" != "$ref" ]; then
                    echo "$name: $ref → $newest (newer tag available)"
                    found=1
                fi
            fi
            continue
        fi
        # Branch pin.
        sha="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
        if [ -n "$sha" ] && [ "$sha" != "$locked_sha" ]; then
            echo "$name: $ref @ ${locked_sha:0:10} → ${sha:0:10} (branch moved)"
            found=1
        fi
    done < <(just --justfile "$jf" plug _read-lock)
    if [ "$found" -eq 0 ]; then
        echo "all modules up to date"
    fi

# Bootstrap a project for just-plug. Idempotent.
init:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
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
