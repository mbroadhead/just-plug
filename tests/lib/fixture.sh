# tests/lib/fixture.sh — spin up a local fixture: bare git repos + raw HTTP server.
#
# Usage:
#   . tests/lib/fixture.sh
#   fixture_setup "$TMPDIR"
#   fixture_add_module "<owner>/<repo>" "<entry-file>" "<tag>" "<content>"
#   # ... run plug commands against the fixture ...
#   fixture_teardown
#
# After fixture_setup, JUST_PLUG_GIT_BASE and JUST_PLUG_RAW_BASE point at the fixture.

# Internal state.
_FIXTURE_ROOT=""
_FIXTURE_GIT_ROOT=""
_FIXTURE_RAW_ROOT=""
_FIXTURE_HTTP_PID=""

fixture_setup() {
    # Kill any previously running server.
    if [ -n "$_FIXTURE_HTTP_PID" ]; then
        kill "$_FIXTURE_HTTP_PID" 2>/dev/null || true
        wait "$_FIXTURE_HTTP_PID" 2>/dev/null || true
        _FIXTURE_HTTP_PID=""
    fi

    local base="$1"
    _FIXTURE_ROOT="$base"
    _FIXTURE_GIT_ROOT="$base/git"
    _FIXTURE_RAW_ROOT="$base/raw"
    mkdir -p "$_FIXTURE_GIT_ROOT" "$_FIXTURE_RAW_ROOT"

    # Start a tiny HTTP server serving _FIXTURE_RAW_ROOT.
    # Use -u (unbuffered) so the startup message is written immediately.
    python3 -u -m http.server 0 --directory "$_FIXTURE_RAW_ROOT" \
        >"$base/http.log" 2>&1 &
    _FIXTURE_HTTP_PID=$!

    # Wait for the server to print its port.
    local port=""
    for _ in $(seq 1 50); do
        port="$(grep -oE 'port [0-9]+' "$base/http.log" 2>/dev/null | head -1 | awk '{print $2}' || true)"
        if [ -n "$port" ]; then break; fi
        sleep 0.05
    done
    if [ -z "$port" ]; then
        echo "fixture_setup: HTTP server did not start; log:" >&2
        cat "$base/http.log" >&2
        return 1
    fi

    export JUST_PLUG_GIT_BASE="file://$_FIXTURE_GIT_ROOT"
    export JUST_PLUG_RAW_BASE="http://127.0.0.1:$port"
}

# fixture_add_module <owner/repo> <entry-file> <ref> <content>
#
# Creates a bare repo at $_FIXTURE_GIT_ROOT/<owner>/<repo> with one commit
# containing <entry-file>, tags it as <ref>, and mirrors the file content to
# $_FIXTURE_RAW_ROOT/<owner>/<repo>/<sha>/<entry-file> so the HTTP server
# can serve it at the same path raw.githubusercontent.com would.
fixture_add_module() {
    local repo="$1" file="$2" ref="$3" content="$4"
    local work="$_FIXTURE_ROOT/work/$repo"
    local bare="$_FIXTURE_GIT_ROOT/$repo"

    mkdir -p "$(dirname "$work")" "$(dirname "$bare")"
    rm -rf "$work" "$bare"
    mkdir -p "$work"

    (
        cd "$work"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        printf '%s' "$content" > "$file"
        git add "$file"
        git -c user.email=t@t -c user.name=t commit -q -m "add $file"
        git tag "$ref"
        git clone -q --bare . "$bare"
    )

    # Allow `git fetch --depth 1 origin <sha>` against the bare repo (mirrors
    # GitHub's platform-wide uploadpack.allowReachableSHA1InWant default).
    git -C "$bare" config uploadpack.allowAnySHA1InWant true

    # Mirror file content for HTTP fetch keyed by the resolved SHA.
    local sha
    sha="$(git -C "$bare" rev-parse "$ref")"
    mkdir -p "$_FIXTURE_RAW_ROOT/$repo/$sha"
    printf '%s' "$content" > "$_FIXTURE_RAW_ROOT/$repo/$sha/$file"

    # Also mirror under the branch name (main) so default-ref tests work.
    local main_sha
    main_sha="$(git -C "$bare" rev-parse main)"
    mkdir -p "$_FIXTURE_RAW_ROOT/$repo/$main_sha"
    printf '%s' "$content" > "$_FIXTURE_RAW_ROOT/$repo/$main_sha/$file"
}

fixture_teardown() {
    if [ -n "$_FIXTURE_HTTP_PID" ]; then
        kill "$_FIXTURE_HTTP_PID" 2>/dev/null || true
        wait "$_FIXTURE_HTTP_PID" 2>/dev/null || true
        _FIXTURE_HTTP_PID=""
    fi
    _FIXTURE_ROOT=""
    _FIXTURE_GIT_ROOT=""
    _FIXTURE_RAW_ROOT=""
    unset JUST_PLUG_GIT_BASE JUST_PLUG_RAW_BASE
}
