# just-plug — a package manager for justfile modules.
# Bootstrap: curl -fsSL https://raw.githubusercontent.com/<owner>/just-plug/main/plug.just > just-plug/plug.just
#
# All recipes anchor paths to justfile_directory(), which resolves to the
# user's project root (the directory containing the justfile that imported this module).

# Print this help message and list just-plug recipes.
help:
    @just --justfile '{{justfile()}}' --list plug
    @echo ''
    @echo 'Docs: https://github.com/mbroadhead/just-plug#readme'

# Default recipe — runs when `just plug` is invoked with no arguments.
[private]
default: help

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

# Report whether <name> is already taken in the user's justfile. A module name
# and a recipe name share one namespace, and an overlap is fatal to the entire
# justfile — including the `plug` module, so just-plug cannot undo it afterwards.
#
# Prints one of:
#   recipe   — a recipe (public, private, or an alias) already has this name
#   module   — a module already has this name
#   free     — the name is available
#   unknown  — the justfile does not currently parse, so nothing can be probed
#
# `--show` is used for recipes rather than `--summary` because `--summary` hides
# private recipes, which collide just as fatally.
_name-status name:
    #!/usr/bin/env bash
    set -euo pipefail
    jf='{{justfile()}}'
    name='{{name}}'
    if ! just --justfile "$jf" --summary >/dev/null 2>&1; then
        echo unknown
    elif just --justfile "$jf" --show "$name" >/dev/null 2>&1; then
        echo recipe
    elif just --justfile "$jf" --list "$name" >/dev/null 2>&1; then
        echo module
    else
        echo free
    fi

# Print the entry filename a source publishes: the repo basename, minus a
# leading `just-`, plus `.just`. This is the name of the file inside the repo,
# which is fixed by the publisher — unlike the local module name, which `install
# --as` can override. Every fetch names the remote file with this, and the local
# artifact with the module name.
_entry-file source:
    #!/usr/bin/env bash
    set -euo pipefail
    repo='{{source}}'
    repo="${repo%/}"
    repo="${repo%.git}"
    repo="${repo##*/}"
    echo "${repo#just-}.just"

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

# Read just-plug.deps, emitting "<name> <source> <ref>" per line.
# Skips blank lines and lines starting with #. Missing file → no output.
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

# Read just-plug.lock, emitting "<name> <source> <ref> <sha> <hash>" per line.
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

# Insert or update a deps entry by name.
# Args: <name> <source> <ref>
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

# Remove a deps entry by name.
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

# Insert or update a lock entry by name.
# Args: <name> <source> <ref> <sha> <hash>
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

# Remove a lock entry by name.
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

# Regenerate just-plug/modules.just from just-plug.lock.
# One `mod? <name> "<name>.just"` line per locked entry, sorted.
# Paths are relative to modules.just's own location (just-plug/), so just-plug/
# resolves them correctly when `import?`ed from a parent justfile.
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

# Install a single module, or (no args) reconcile state against just-plug.deps.
# Usage: just plug install [github.com/<owner>/<repo>[@<ref>]] [--as <name>]
install spec="" *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    jf='{{justfile()}}'

    spec='{{spec}}'

    # --as <name> overrides the module name derived from the repo basename.
    alias=""
    set -- {{flags}}
    # `install --as x` binds --as to the spec parameter positionally; hand it
    # back to the option parser so the error names --as rather than its argument.
    case "$spec" in
        -*) set -- "$spec" "$@"; spec="" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --as)
                shift
                if [ $# -eq 0 ]; then
                    echo "error: --as requires a module name" >&2
                    exit 1
                fi
                alias="$1"
                ;;
            --as=*) alias="${1#--as=}" ;;
            *)
                echo "error: unknown option: $1" >&2
                echo "       usage: just plug install [<source>[@<ref>]] [--as <name>]" >&2
                exit 1
                ;;
        esac
        shift
    done

    if [ -z "$spec" ] && [ -n "$alias" ]; then
        echo "error: --as requires a source to install" >&2
        exit 1
    fi

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
                sha="$(just --justfile "$jf" plug _resolve-ref "$source" "$ref")"
                hash_recorded=""
            fi
            # If file already present and lock has hash, only re-fetch when missing.
            if [ -f "$root/just-plug/$name.just" ] && [ -n "$hash_recorded" ]; then
                : # leave it
            else
                entry="$(just --justfile "$jf" plug _entry-file "$source")"
                hash_recorded="$(just --justfile "$jf" plug _fetch "$source" "$sha" "$entry" "$root/just-plug/$name.just")"
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
    name="${alias:-${repo#just-}}"
    if [ -z "$name" ]; then
        echo "error: derived module name is empty for source $source" >&2
        exit 1
    fi

    # The name becomes a `mod` identifier in the user's justfile, so it has to
    # be a legal one — a repo like just-my.thing derives a name that is not.
    if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        echo "error: '$name' is not a valid module name" >&2
        echo "       names must match [a-zA-Z_][a-zA-Z0-9_-]*" >&2
        echo "       install it under a different name:" >&2
        echo "           just plug install $spec --as <name>" >&2
        exit 1
    fi

    # Collision check: same name, different source already installed?
    existing_src=""
    if [ -f "$root/just-plug.lock" ]; then
        existing_src="$(awk -v n="$name" '$1 == n {print $2}' "$root/just-plug.lock")"
        if [ -n "$existing_src" ] && [ "$existing_src" != "$source" ]; then
            echo "error: module '$name' is already installed from $existing_src" >&2
            echo "       install this one under a different name:" >&2
            echo "           just plug install $spec --as <name>" >&2
            echo "       or remove the other first with: just plug remove $name" >&2
            exit 1
        fi
    fi

    # Namespace check: would this name collide with something already in the
    # user's justfile? Skipped when we are re-installing our own module, whose
    # name is already in modules.just and would report as a collision.
    name_status=skipped
    if [ "$existing_src" != "$source" ]; then
        name_status="$(just --justfile "$jf" plug _name-status "$name")"
    fi
    case "$name_status" in
        recipe|module)
            echo "error: '$name' is already a $name_status in your justfile" >&2
            echo "       installing it would leave the whole justfile unparseable" >&2
            echo "       install it under a different name:" >&2
            echo "           just plug install $spec --as <name>" >&2
            exit 1
            ;;
        unknown)
            echo "warning: your justfile does not parse, so '$name' was not checked for conflicts" >&2
            ;;
    esac

    # Resolve ref → SHA.
    sha="$(just --justfile "$jf" plug _resolve-ref "$source" "$ref")"

    # Fetch the repo's entry file into just-plug/<name>.just (atomic).
    mkdir -p "$root/just-plug"
    entry="$(just --justfile "$jf" plug _entry-file "$source")"
    hash="$(just --justfile "$jf" plug _fetch "$source" "$sha" "$entry" "$root/just-plug/$name.just")"

    # Back up what the install is about to mutate. Rollback has to be plain cp:
    # _remove-dep and _gen-modules are sub-`just` calls, and none of them can run
    # once the justfile has stopped parsing.
    backup="$(mktemp -d)"
    trap 'rm -rf "$backup"' EXIT
    for f in just-plug.deps just-plug.lock just-plug/modules.just; do
        if [ -f "$root/$f" ]; then
            mkdir -p "$backup/$(dirname "$f")"
            cp "$root/$f" "$backup/$f"
        fi
    done

    # Update state.
    just --justfile "$jf" plug _upsert-dep "$name" "$source" "$ref"
    just --justfile "$jf" plug _upsert-lock "$name" "$source" "$ref" "$sha" "$hash"
    just --justfile "$jf" plug _gen-modules

    # Backstop for whatever the checks above did not anticipate: the justfile
    # parsed before this install, so if it does not now, this install is why.
    if [ "$name_status" = "free" ] && ! just --justfile "$jf" --summary >/dev/null 2>&1; then
        parse_error="$(just --justfile "$jf" --summary 2>&1 || true)"
        rm -f "$root/just-plug/$name.just"
        for f in just-plug.deps just-plug.lock just-plug/modules.just; do
            if [ -f "$backup/$f" ]; then cp "$backup/$f" "$root/$f"; else rm -f "$root/$f"; fi
        done
        echo "error: installing '$name' left your justfile unparseable; rolled back" >&2
        echo "$parse_error" >&2
        echo "       install it under a different name:" >&2
        echo "           just plug install $spec --as <name>" >&2
        exit 1
    fi

    echo "installed $name @ $ref ($sha)"

# Remove an installed module.
remove name:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
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
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
    name='{{name}}'
    jf='{{justfile()}}'

    update_one() {
        local n="$1" src="$2" ref="$3"
        local new_sha old_sha old_hash new_hash entry
        new_sha="$(just --justfile "$jf" plug _resolve-ref "$src" "$ref")"
        old_sha="$(awk -v n="$n" '$1==n {print $4}' "$root/just-plug.lock" 2>/dev/null || true)"
        old_hash="$(awk -v n="$n" '$1==n {print $5}' "$root/just-plug.lock" 2>/dev/null || true)"
        if [ "$new_sha" = "$old_sha" ] && [ -f "$root/just-plug/$n.just" ]; then
            return 0  # no change
        fi
        entry="$(just --justfile "$jf" plug _entry-file "$src")"
        new_hash="$(just --justfile "$jf" plug _fetch "$src" "$new_sha" "$entry" "$root/just-plug/$n.just")"
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
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
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
    while read -r name source ref locked_sha hash; do
        [ -z "$name" ] && continue
        # SHA pin: never outdated.
        if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
            continue
        fi
        url="$(just --justfile "$jf" plug _source-to-url "$source")"
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

# Update just-plug itself. Defaults to github.com/mbroadhead/just-plug@main.
# Usage: just plug self-update [<spec>|@<ref>]
self-update spec="":
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    if [ -n "${JUST_PLUG_DIR:-}" ]; then
        case "$JUST_PLUG_DIR" in
            /*) root="$JUST_PLUG_DIR" ;;
            *)  root="$root/$JUST_PLUG_DIR" ;;
        esac
    fi
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

# Bootstrap a project for just-plug. Idempotent.
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
