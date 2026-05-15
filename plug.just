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
