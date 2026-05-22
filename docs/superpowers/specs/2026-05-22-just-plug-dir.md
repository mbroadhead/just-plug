# JUST_PLUG_DIR: configurable artifact location

## Problem

Today, every just-plug artifact is anchored at `{{justfile_directory()}}`:

```
<justfile_directory>/just-plug.deps
<justfile_directory>/just-plug.lock
<justfile_directory>/just-plug/{plug.just, modules.just, <module>.just}
```

`justfile_directory()` resolves to the directory of the top-level justfile that
`just` was invoked with — i.e. the project root. There is no way to place
artifacts anywhere else.

The motivating use case: a project keeps machine- or checkout-local concerns
under a `.local/` subdirectory, loaded from the root justfile via
`import? '.local/justfile.private'`. The user wants just-plug to install into
`.local/just-plug/` (with `just-plug.deps` / `just-plug.lock` alongside it
under `.local/`), so that all of just-plug's state lives in one tidy subdir
that's gitignored together. Running `just plug install …` from the project
root must still work.

There is no escape hatch for this today.

## Solution

Introduce `JUST_PLUG_DIR`, an environment variable that overrides
`{{justfile_directory()}}` as the anchor for just-plug's artifacts.

### Resolution rules

| `JUST_PLUG_DIR` value | Resolved root |
|---|---|
| unset or empty | `{{justfile_directory()}}` (today's behavior) |
| absolute path (starts with `/`) | the path as-is |
| relative path | `{{justfile_directory()}}/$JUST_PLUG_DIR` |

Relative paths resolve against `justfile_directory()` — **not** the current
working directory — so behavior is independent of where the user runs `just`
from. This matches every other path in plug.just.

### Resulting layout

With `JUST_PLUG_DIR=.local`:

```
<project>/
├── justfile                           # `import? '.local/justfile.private'`
└── .local/
    ├── justfile.private               # `mod? plug "just-plug/plug.just"`
    │                                  # `import? "just-plug/modules.just"`
    ├── just-plug.deps
    ├── just-plug.lock
    └── just-plug/
        ├── plug.just
        ├── modules.just
        └── <module>.just
```

### How users set it

Any mechanism that puts `JUST_PLUG_DIR` in the shell environment before `just`
runs will work. Recommended: a per-checkout tool like
[mise](https://mise.jdx.dev/) via `mise.local.toml`:

```toml
[env]
JUST_PLUG_DIR = ".local"
```

Plain `direnv` (`.envrc`), shell exports, and one-shot
`JUST_PLUG_DIR=.local just plug install …` invocations all work equivalently.
The env-var approach sidesteps any question about whether just's `export`
propagates across `mod?` boundaries, because the variable is already in the
environment by the time `just` starts.

## Affected recipes

Every recipe that currently binds `root='{{justfile_directory()}}'` or
references `{{justfile_directory()}}` directly to construct an artifact path.
By inspection of `plug.just`:

- `_paths` — prints the resolved root and derived paths.
- `_read-deps`, `_read-lock` — read `<root>/just-plug.deps` / `.lock`.
- `_upsert-dep`, `_remove-dep`, `_upsert-lock`, `_remove-lock` — write the
  same files.
- `_gen-modules` — writes `<root>/just-plug/modules.just`.
- `install` (both reconcile and single-install modes) — reads deps, writes
  modules into `<root>/just-plug/`.
- `remove` — deletes `<root>/just-plug/<name>.just`.
- `update` — re-fetches into `<root>/just-plug/<name>.just`.
- `verify` — reads `<root>/just-plug/<name>.just`.
- `outdated` — pure-read of state; needs the same root resolution.
- `self-update` — writes `<root>/just-plug/plug.just`.
- `init` — creates `<root>/just-plug/` and touches `<root>/just-plug.deps`.

Recipes that **don't** touch artifact paths (`_parse-source`,
`_source-to-url`, `_resolve-ref`, `_fetch`, `list`, `help`, `default`) are
unaffected.

## Implementation pattern

Each affected recipe is a self-contained bash script. The resolution is
inlined as four lines wherever a `root` variable is currently bound (and
introduced in the few helpers that don't have one):

```bash
root='{{justfile_directory()}}'
if [ -n "${JUST_PLUG_DIR:-}" ]; then
    case "$JUST_PLUG_DIR" in
        /*) root="$JUST_PLUG_DIR" ;;
        *)  root="$root/$JUST_PLUG_DIR" ;;
    esac
fi
```

Inlining keeps each recipe self-contained (no per-call sub-`just` invocation
for a helper) and is straightforward to grep for during maintenance.

### `_paths` updates

`_paths` is used by tests to discover artifact locations. It currently prints:

```
ROOT={{justfile_directory()}}
DEPS={{justfile_directory()}}/just-plug.deps
LOCK={{justfile_directory()}}/just-plug.lock
PLUGDIR={{justfile_directory()}}/just-plug
MODSFILE={{justfile_directory()}}/just-plug/modules.just
```

It will be rewritten to resolve `root` first, then print the same five lines
using the resolved value. Tests that use `_paths` to locate files
automatically follow the new location with no changes.

### `init` updates

`init` currently does `mkdir -p "$root/just-plug"` and touches
`"$root/just-plug.deps"`. With `JUST_PLUG_DIR` pointing somewhere that
doesn't yet exist, `mkdir -p` already creates the intermediate directories,
so no extra change is strictly required.

The bootstrap message currently shows:

```
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
```

These paths are correct when the user pastes them into a justfile **sitting
next to** `just-plug/` (the common case, and the case when `JUST_PLUG_DIR`
is unset). When `JUST_PLUG_DIR` is set, we can't predict where the user
will paste the lines — they may go in a justfile at the project root, in
an imported sub-justfile next to `just-plug/`, or somewhere else entirely.
Rather than guess and risk being wrong, the message keeps the canonical
relative form (`just-plug/plug.just`) and appends a one-line note showing
where artifacts actually landed:

```
just-plug ready. Add these two lines to a justfile in <resolved-root>
(adjust the relative paths if you import them from elsewhere):

    mod? plug "just-plug/plug.just"
    import? "just-plug/modules.just"
```

The note is only printed when `JUST_PLUG_DIR` is set. When unset, the
message is unchanged.

## Documentation

`README.md` gets a new "Custom artifact location" section after "File
layout". It documents the env var, the resolution rules, and shows the
`mise.local.toml` pattern alongside the resulting file layout. The "File
layout" section is updated to note that the layout is rooted at
`$JUST_PLUG_DIR` (defaulting to the project root).

The bootstrap snippet in "Install" stays as-is (it manually places
`just-plug/plug.just` before plug.just is ever run), but a one-line note
mentions that users who want artifacts elsewhere can `mkdir -p
.local/just-plug` and curl into there instead.

## Testing

Add one integration test: `tests/integration/test_just_plug_dir.sh`.

Coverage:

1. Set `JUST_PLUG_DIR=tools` (relative path) in the test environment.
2. Run `just plug init`, then `just plug install` against a fixture module.
3. Assert that `<root>/tools/just-plug.deps`, `<root>/tools/just-plug.lock`,
   and `<root>/tools/just-plug/<name>.just` exist.
4. Assert that `<root>/just-plug.deps` / `<root>/just-plug.lock` /
   `<root>/just-plug/` do **not** exist.
5. Run `just plug list` and `just plug verify` to confirm they read the
   relocated state correctly.
6. Run `just plug remove <name>` and assert the file is removed from the
   relocated `just-plug/` directory.

Existing tests (which don't set `JUST_PLUG_DIR`) verify the default-path
behavior is unchanged.

An absolute-path case (`JUST_PLUG_DIR=/tmp/jp-test-XXX`) is not separately
tested — the resolution branch is a one-line `case`, and the relative case
exercises every recipe.

## Backward compatibility

When `JUST_PLUG_DIR` is unset or empty, behavior is byte-identical to today.
No existing project or test needs to change. The change is purely additive.

## Out of scope

- Customizing the file names (`just-plug.deps`, `just-plug.lock`,
  `just-plug/`, `modules.just`). The directory is the only configurable axis.
- A CLI flag form (`just plug --dir=…`). Env var is sufficient for the
  motivating use case and composes with shell tooling.
- Multiple parallel locations within one project. Not a real use case.
