# Module name conflicts and `--as` aliasing

Extends [the original just-plug design](2026-05-15-just-plug-design.md). Makes the local module name a user-controllable choice, and refuses installs that would break the user's justfile instead of letting them break it.

## 1. Motivation

The local module name is derived from the repo basename and is not negotiable. `import? "just-plug/modules.just"` splices `mod? doit "doit.just"` straight into the user's namespace, and just treats module names and recipe names as one namespace:

```
$ just doit
error: Module `doit` defined on line 1 is redefined as a recipe on line 74
  ——▶ justfile:74:1
```

Two things make this worse than an ordinary error:

- It is fatal to the **whole** justfile, not just the offending module. Every recipe in the project stops working.
- It is fatal to just-plug itself. `just plug remove doit` also has to parse the justfile, so the tool that caused the problem cannot be used to undo it.

There is no supported way out today: the derived name is the only name a module can have.

## 2. CLI shape

```
just plug install <spec> [--as <name>]
```

`--as` sets the local module name, overriding the name derived from the repo basename. It applies to single-module installs only; `just plug install --as x` with no spec is an error.

```sh
just plug install github.com/foo/just-doit --as tasks
```

Everything downstream keys on the local name, unchanged:

```sh
just plug update tasks
just plug remove tasks
just tasks <recipe>
```

## 3. Local name vs. remote filename

The local name currently does double duty: it names the file inside the repo that gets fetched *and* the local artifact. `--as` splits them.

| | Value | Derived from |
|---|---|---|
| Remote entry file | `doit.just` | the source repo basename, minus a leading `just-` |
| Local file | `just-plug/tasks.just` | the local name |
| `just-plug.deps` / `.lock` key | `tasks` | the local name |
| `modules.just` entry | `mod? tasks "tasks.just"` | the local name |

The remote filename is always derivable from `source`, which both state files already record, so **neither file format changes** — `name` is already column 1 of each.

## 4. Install-time checks

Before fetching anything, `install` rejects three cases with an actionable message.

1. **Invalid module name.** The name must match just's identifier grammar, `^[a-zA-Z_][a-zA-Z0-9_-]*$`. A repo named `just-my.thing` derives `my.thing`, which is not a legal `mod` name and produces a parse error today.
2. **Name already in use in the user's justfile.** Probed against the root justfile with `just --show <name>` (recipes, including private ones, which `--summary` hides) and `just --list <name>` (modules).
3. **Name already installed from a different source.** Already implemented; the message gains the `--as` suggestion.

Each error names `--as` and prints the exact command to run:

```
error: `doit` is already a recipe in your justfile
       install it under a different name:
           just plug install github.com/foo/just-doit --as <name>
```

If the root justfile does not currently parse, the probes cannot distinguish "free" from "taken". In that case `install` prints a warning, skips checks 2 and 3, and proceeds — a broken justfile is not just-plug's to diagnose.

## 5. Rollback

Checks 1–3 cover the known ways an install breaks a justfile. As a backstop for the unknown ones, `install` copies `just-plug.deps`, `just-plug.lock`, and `modules.just` aside before mutating them, and re-parses the root justfile afterwards. If the justfile parsed before the install and does not after, the three files are restored, the fetched module is deleted, and just's own parse error is reported.

The restore is done with `cp`, not with the `_remove-dep` / `_remove-lock` / `_gen-modules` helpers: those are sub-`just` invocations, and in the broken state they cannot run.

## 6. Out of scope

- **`just plug rename`.** Renaming an installed module in place is `remove` then `install --as`. A dedicated recipe would need to rewrite deps, lock, the local file, and `modules.just` for a case that comes up once.
- **Auto-renaming on conflict** (`doit` → `doit2`). Makes recipe names depend on install order, so they differ between machines that installed the same modules in different sequences.
- **Namespacing every module under one parent** (`just plug docker build`). Structurally removes the whole class of conflict, but breaks every existing call site and demotes modules to second-class citizens.
- **A conflict check in `verify`.** Unreachable: a conflict stops `just plug verify` from parsing in the first place. CI already fails loudly with just's own message. The README documents the rescue command instead.
- **Conflicts introduced after install** (the user adds a recipe that shadows an installed module). Not preventable from inside just-plug; covered by documentation.

## 7. Recovering from an existing conflict

Because every `just` command in the project fails, recovery has to bypass the broken justfile. `JUST_PLUG_DIR` already provides the way in:

```sh
JUST_PLUG_DIR=.. just -f just-plug/plug.just remove doit
```

`-f` parses `plug.just` alone (so the conflicting `mod` line is never read), and `JUST_PLUG_DIR=..` points the artifact paths back at the project root, which `justfile_directory()` would otherwise resolve to `just-plug/`.

## 8. Testing

One integration test, `tests/integration/test_name_conflicts.sh`, on the existing `file://` fixture harness:

1. `--as` installs to the aliased name: `just-plug/tasks.just` exists, `doit.just` does not, deps/lock are keyed `tasks`, `modules.just` reads `mod? tasks "tasks.just"`, and the justfile still parses.
2. `just plug update tasks` refetches by alias (the remote file is still `doit.just`) and `just plug remove tasks` removes it.
3. Installing a module whose derived name collides with an existing recipe fails, mentions `--as`, and leaves no file, deps entry, or lock entry behind.
4. The same install with `--as` succeeds.
5. A source deriving an illegal name (`just-my.thing`) fails and mentions `--as`.

One unit test, `tests/unit/test_entry_file.sh`, for the remote-filename derivation across bare, HTTPS, SSH, and `file://` source forms.

## 9. README

A subsection under Module naming covering `--as`, when to reach for it, and the recovery command from §7.
