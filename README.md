# just-plug

A package manager for [just](https://just.systems) modules. Install third-party justfile modules from GitHub, pinned to a specific version, recorded in a manifest and lockfile.

## Install

```sh
mkdir -p just-plug
curl -fsSL https://raw.githubusercontent.com/mbroadhead/just-plug/main/plug.just > just-plug/plug.just
```

Add two lines to your `justfile`:

```just
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
```

Run `just plug init` to create the manifest file.

## Usage

```sh
# List recipes (also runs with bare `just plug`).
just plug help

# Install a module from GitHub. Default ref is `main`.
just plug install github.com/foo/just-docker
just plug install github.com/foo/just-docker@v1.2.0
just plug install github.com/foo/just-docker@develop
just plug install github.com/foo/just-docker@abc1234

# URL forms — useful for paste-from-`git remote -v` and required for private repos.
just plug install https://github.com/foo/just-docker.git
just plug install git@github.com:foo/just-docker.git@v1.2.0

# Install under a name of your choosing (see Module naming).
just plug install github.com/foo/just-docker --as containers

# Remove a module.
just plug remove docker

# List installed modules.
just plug list

# Update a module (re-resolve and refetch if the SHA moved).
just plug update docker
just plug update                 # all modules

# Verify installed files against the lockfile.
just plug verify

# Check whether any modules have newer versions available.
just plug outdated

# Update just-plug itself (defaults to mbroadhead/just-plug@main).
just plug self-update
just plug self-update @v1.0.0

# Reconcile: install everything in just-plug.deps, remove orphans.
just plug install
```

## Module naming

The local module name is derived from the repo basename, with a leading `just-` stripped:

| Source | Module name | Local file |
|---|---|---|
| `github.com/foo/just-docker` | `docker` | `just-plug/docker.just` |
| `github.com/foo/docker` | `docker` | `just-plug/docker.just` |

To publish a module: drop a single `.just` file named `<module-name>.just` at the root of a public GitHub repo. Conventionally, name the repo `just-<module-name>`.

### Choosing a different name

Module names and recipe names share one namespace. If a module's derived name is already a recipe in your justfile, `just` refuses to parse the file at all — every recipe in the project stops working, not just that module:

```
error: Module `docker` defined on line 1 is redefined as a recipe on line 74
```

`install` checks for this and refuses rather than letting it happen. Install under a different name with `--as`:

```sh
just plug install github.com/foo/just-docker --as containers
```

The name you pick is the name everything else uses — `just containers <recipe>`, `just plug update containers`, `just plug remove containers` — and it is what lands in `just-plug.deps`, `just-plug.lock`, and `just-plug/containers.just`. The file fetched from the repo is unaffected.

`--as` is also the answer when two modules derive the same name (`foo/just-docker` and `bar/just-docker`), or when a repo name is not a legal `just` identifier (`just-my.thing`).

### Recovering from a conflict

A bare `just plug install`, which reconciles against `just-plug.deps`, checks the same thing a different way: it restores `just-plug.deps`, `just-plug.lock`, and `just-plug/` if the justfile stops parsing. This is the case to expect on a fresh clone, since `mod?` and `import?` are optional — a justfile that shadows a name in `just-plug.deps` parses fine until someone installs the modules and `just-plug/modules.just` appears.

If a conflict already exists — usually because a recipe was added to the justfile *after* the module was installed — then `just plug remove` cannot run either, since it also has to parse the broken justfile. Run `plug.just` directly instead:

```sh
JUST_PLUG_DIR=.. just -f just-plug/plug.just remove <name>
```

`-f` parses `plug.just` alone, so the conflicting `mod` line is never read, and `JUST_PLUG_DIR=..` points the artifact paths back at your project root. Reinstall with `--as` afterwards.

## Publishing a module

Start from [just-plug-template](https://github.com/mbroadhead/just-plug-template):

1. Click **Use this template** on the template repo (or `gh repo create --template mbroadhead/just-plug-template`).
2. Clone your new repo and run `bash scripts/init.sh` — it prompts for the module name, replaces placeholders, renames the sample `MODULE.just`, and removes itself.
3. Edit the renamed `<module-name>.just` to write your real recipes.
4. Commit, push, and tag a release: `git tag v0.1.0 && git push --tags`.

A CI workflow checks the module parses on every push; the release workflow creates a GitHub Release on every `v*` tag so versioned installs (`...@v0.1.0`) stay discoverable.

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

## Limitations (v1)

- GitHub-only for the bare `github.com/owner/repo` form. URL forms (HTTPS and SSH) work for any host `git` understands, but only GitHub is exercised in tests.
- One module per repo.
- No transitive dependencies.
- No semver ranges — pin to a tag, branch, or SHA.
- `outdated` for tag pins uses `sort -V` and may misbehave on unusual tag formats.
- Repos whose default branch isn't `main` require an explicit `@master` (or whatever) ref.
