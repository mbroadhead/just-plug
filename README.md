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

## Limitations (v1)

- GitHub-only for the bare `github.com/owner/repo` form. URL forms (HTTPS and SSH) work for any host `git` understands, but only GitHub is exercised in tests.
- One module per repo.
- No transitive dependencies.
- No semver ranges — pin to a tag, branch, or SHA.
- `outdated` for tag pins uses `sort -V` and may misbehave on unusual tag formats.
- Repos whose default branch isn't `main` require an explicit `@master` (or whatever) ref.
