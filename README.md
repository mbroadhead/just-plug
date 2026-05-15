# just-plug

A package manager for [just](https://just.systems) modules. Install third-party justfile modules from GitHub, pinned to a specific version, recorded in a manifest and lockfile.

## Install

```sh
mkdir -p just-plug
curl -fsSL https://raw.githubusercontent.com/<owner>/just-plug/main/plug.just > just-plug/plug.just
```

Add two lines to your `justfile`:

```just
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
```

Run `just plug init` to create the manifest file.

## Usage

```sh
# Install a module from GitHub. Default ref is `main`.
just plug install github.com/foo/just-docker
just plug install github.com/foo/just-docker@v1.2.0
just plug install github.com/foo/just-docker@develop
just plug install github.com/foo/just-docker@abc1234

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

- GitHub-only. No GitLab/Codeberg/raw URLs.
- One module per repo.
- No transitive dependencies.
- No semver ranges — pin to a tag, branch, or SHA.
- `outdated` for tag pins uses `sort -V` and may misbehave on unusual tag formats.
- Repos whose default branch isn't `main` require an explicit `@master` (or whatever) ref.
