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
