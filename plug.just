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

# Parse a source identifier of the form github.com/<owner>/<repo>[@<ref>].
# Outputs three space-separated fields on stdout: <name> <source> <ref>.
# Exits non-zero on invalid input.
_parse-source spec:
    #!/usr/bin/env bash
    set -euo pipefail
    spec='{{spec}}'

    # Split off ref.
    if [[ "$spec" == *"@"* ]]; then
        ref="${spec##*@}"
        source="${spec%@*}"
    else
        ref="main"
        source="$spec"
    fi

    # Validate: must be github.com/<owner>/<repo> with no extra path components.
    if [[ ! "$source" =~ ^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        echo "error: source must look like 'github.com/<owner>/<repo>', got: $source" >&2
        exit 1
    fi

    # Derive name: repo basename minus leading 'just-'.
    repo="${source##*/}"
    name="${repo#just-}"

    if [ -z "$name" ]; then
        echo "error: derived module name is empty for source $source" >&2
        exit 1
    fi

    echo "$name $source $ref"

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
# One `mod? <name> "just-plug/<name>.just"` line per locked entry, sorted.
_gen-modules:
    #!/usr/bin/env bash
    set -euo pipefail
    lock='{{justfile_directory()}}/just-plug.lock'
    out='{{justfile_directory()}}/just-plug/modules.just'
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp "${out}.XXXXXX")"
    if [ -f "$lock" ]; then
        awk 'NF && $1 !~ /^#/ {print "mod? " $1 " \"just-plug/" $1 ".just\""}' "$lock" | sort > "$tmp"
    else
        : > "$tmp"
    fi
    mv "$tmp" "$out"

# Install a single module. Usage: just plug install github.com/<owner>/<repo>[@<ref>]
install spec:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{justfile_directory()}}'
    jf='{{justfile()}}'

    # Parse inline (mirrors _parse-source logic) to avoid sub-just cwd issues.
    spec='{{spec}}'
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
