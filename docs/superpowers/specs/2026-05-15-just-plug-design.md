# just-plug — Design

A package manager for justfile modules. The package manager itself ships as a single justfile module (`plug.just`), installed with one `curl` command. All operations are `just plug <command>`.

## 1. Concept

`just-plug` lets users install third-party justfile modules from GitHub the same way they'd install gems, npm packages, or Go modules — pinned to a specific version, recorded in a manifest, reproducible via a lockfile.

The package manager is self-hosting: `plug.just` is itself a `.just` module that you `mod?` into your justfile. Bootstrap is a single `curl` command; everything after that is a `just plug ...` recipe.

## 2. Bootstrap

```sh
mkdir -p just-plug
curl -fsSL https://raw.githubusercontent.com/<owner>/just-plug/main/plug.just > just-plug/plug.just
```

(`<owner>` is the GitHub account that hosts the canonical `just-plug` repo. To be set when the project's home is chosen.)

Then the user adds two lines to their `justfile`:

```just
mod? plug "just-plug/plug.just"
import? "just-plug/modules.just"
```

The first line exposes `just plug <command>`. The second line pulls in the auto-generated `mod?` directives for any modules the user installs through `plug`. `modules.just` is created lazily by `plug` — the `import?` (with `?`) makes the line a no-op until that file exists.

After bootstrap, the user runs `just plug init` to create the `just-plug/` directory and an empty `just-plug.deps`.

## 3. File system layout

```
<project root>/
├── justfile                    # user-owned. Contains the two mod?/import? lines above.
├── just-plug.deps              # user intent. Line-based, awk-parsable.
├── just-plug.lock              # resolved state. Same format + resolved SHA + sha256.
└── just-plug/
    ├── plug.just               # the package manager itself (bootstrapped via curl).
    ├── modules.just            # machine-generated. mod? lines for installed modules.
    ├── docker.just             # an installed module.
    └── aws.just                # another installed module.
```

`just-plug.deps` and `just-plug.lock` live at the project root, mirroring the convention used by `Gemfile`/`package.json`/`Cargo.toml`. The `just-plug/` directory holds the package manager and every module it installs.

## 4. Naming convention

- **Source identifier:** `github.com/<owner>/<repo>` (no scheme, no `.git`, no file suffix). GitHub-only for v1.
- **Module name:** the repo basename with a leading `just-` stripped. `github.com/foo/just-docker` → `docker`. `github.com/foo/docker` → also `docker`. This matches the convention where ecosystem packages prefix themselves (`bundler-rails`, `eslint-config-airbnb`) while keeping the import name clean.
- **Entry file in the source repo:** `<module-name>.just` at the repo root. A repo named `just-docker` must contain `docker.just` at its root.
- **Local install path:** `just-plug/<module-name>.just`.
- **Collision rule:** if a user tries to install two sources that resolve to the same module name, `plug install` refuses with a clear error naming the existing source and file path.

The package manager itself is the canonical example: repo `just-plug`, file `plug.just`, mod name `plug`.

### Tradeoffs accepted

- **One module per repo.** No support for multiple modules in one repo. If a publisher wants two, they make two repos. (Avoids needing a manifest inside module repos.)
- **GitHub-only for v1.** The fetcher hard-codes `raw.githubusercontent.com`. Extending to GitLab/Codeberg/raw URLs is a v2 concern.
- **No transitive dependencies.** A module is one file; if it depends on another module, the *user* installs both. This sidesteps the entire version-resolution rabbit hole for v1.

## 5. Versioning

### Specifier model

Pin to a git ref:

- a **tag** — `@v1.2.0`
- a **branch** — `@main`
- a **commit SHA** — `@abc123def456...`

No semver ranges. What you pin is what you get.

If no `@ref` is given, default to `@main`. The `.deps` file records exactly what the user asked for (`main`, `v1.2.0`, or the SHA). The lockfile records the *resolved* commit SHA at install time. Repos whose default branch is `master` (or anything else) require the user to specify `@master` explicitly — there is no fallback chain.

### Reproducibility

`plug install` (no args) on a fresh checkout uses the lockfile's resolved SHA when present, so a teammate cloning the project gets bit-for-bit the same module files. If the lockfile is missing, `plug install` re-resolves every entry in `.deps` and writes a fresh lock.

`plug update <name>` re-resolves the same ref against the remote and rewrites the lock if the SHA moved. For tag pins this is usually a no-op; for branch pins it's how new commits flow in.

## 6. File formats

### `just-plug.deps` (user-edited)

Whitespace-separated, one module per line, `#` comments allowed, blank lines ignored:

```
# name    source                     ref
docker    github.com/foo/docker      v1.2.0
aws       github.com/bar/aws         main
```

### `just-plug.lock` (machine-managed)

Same shape with two extra columns: the resolved commit SHA and the sha256 of the downloaded file:

```
docker    github.com/foo/docker      v1.2.0   abc123def4567890...   sha256-9f86d081884...
aws       github.com/bar/aws         main     789xyz0123456789...   sha256-2c26b46b68f...
```

### `just-plug/modules.just` (machine-generated)

```just
mod? docker "docker.just"
mod? aws "aws.just"
```

Paths are relative to `modules.just`'s own directory (`just-plug/`), because `just` resolves `mod?` paths relative to the file containing the directive — not the root justfile that imported it.

Regenerated from the lockfile after every `install`/`remove`/`update`. The `mod?` form (with `?`) is used so removing a module file doesn't break justfile evaluation.

All three files are parseable with `awk '{print $1, $2, $3}'`. No TOML parser is required.

## 7. Commands (v1)

| Command | Behavior |
|---|---|
| `plug init` | Create `just-plug/` if missing. Write empty `just-plug.deps` if missing. Print the two `mod?`/`import?` lines for the user to paste into their justfile. Idempotent. |
| `plug install <source>[@ref]` | Resolve ref → fetch `<name>.just` → write `just-plug/<name>.just` → update `.deps` and `.lock` → regenerate `modules.just`. Fails if the derived module name is already installed. |
| `plug install` (no args) | Reconcile. For every entry in `.deps`, ensure the module is installed at the lockfile's SHA (or freshly resolved if no lock entry). Remove any installed module not in `.deps`. Regenerate `modules.just`. |
| `plug remove <name>` | Delete `just-plug/<name>.just`, remove the entry from `.deps` and `.lock`, regenerate `modules.just`. |
| `plug update [name]` | Re-resolve the pinned ref against the remote. Update the lock and re-fetch the file if the SHA changed. With no name, update all modules. |
| `plug list` | Print installed modules with source, pinned ref, resolved SHA. |
| `plug verify` | Re-hash every file in `just-plug/` (except `plug.just` and `modules.just`) and compare to the lock. Non-zero exit on any mismatch. Read-only. |
| `plug outdated` | For each module, `git ls-remote` and report any newer tag (for tag pins) or newer commit on the branch (for branch pins). Read-only. |

## 8. Internals

`plug.just` is a justfile module. Every command is a just recipe that shells out to standard Unix tools.

- **HTTP fetch:** `curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<name>.just`
- **Ref resolution:** `git ls-remote https://github.com/<owner>/<repo> <ref>`. A ref matching `^[0-9a-f]{7,40}$` is treated as a commit SHA and passed through unchanged (no remote round-trip).
- **Hashing:** `shasum -a 256` (BSD/GNU compatible).
- **Manifest/lock I/O:** `awk`, `grep -v`, `sort`. Writes go to a tempfile and are committed with atomic `mv`.
- **`modules.just` generation:** `awk '{print "mod? " $1 " \"" $1 ".just\""}'` over the lock (paths are relative to `modules.just`'s directory, not the project root).

Dependency surface: `bash`, `curl`, `git`, `shasum`, plus `awk`/`grep`/`sed`/`sort`/`mv`/`mkdir`/`rm`/`mktemp`. No TOML parser, no jq, no Python.

### Recipe structure

Each `plug` recipe is a small bash script. Shared helpers (parse-source-id, derive-name, resolve-ref, fetch-to-tempfile, atomic-commit) are defined as private recipes prefixed with `_` so they don't appear in `just --list`.

## 9. Error handling

- **Network / fetch failure** (curl non-zero, 404, timeout): bail with a clear message naming the failed URL. Non-zero exit. Any tempfile is removed; existing `.lock` and `just-plug/` content untouched. In a multi-module install, completed modules stay; the failing module and any after it do not roll back already-committed predecessors. Each module's install is its own transaction.
- **Ref resolution failure** (`git ls-remote` returns no match for `@v1.2.0`): clear message naming the ref. Same no-partial-state guarantee.
- **Name collision** on install: refuse with a message naming the source that already owns the module name and the file path.
- **Drift between `.deps` and `.lock`** (user hand-edited `.deps`): `plug install` (no args) reconciles. Anything in `.deps` not in `.lock` is installed; anything in `.lock` not in `.deps` is removed. `.lock` is rewritten.
- **Hand-edited module files**: detected only by `plug verify` via hash mismatch. Reported, never auto-repaired. To restore, the user runs `plug install` for that module (or `plug update`).
- **Missing `.lock` on `plug install` (no args)**: treat as "no resolved state yet" — re-resolve every entry in `.deps` and write a fresh lock.

## 10. Testing strategy

Every recipe shells out to network or git, so the strategy is layered:

1. **Pure-function unit tests** for the awk/sed pieces: parse a `.deps` line, generate a `modules.just` line, compute the next-state lock after install/remove. Inputs and expected outputs as text fixtures; tests are shell scripts using `diff`.
2. **Integration tests against local fixture repos.** Set up bare git repos in a tempdir, populate them with sample `.just` files, tag a release, and point `plug` at them via `file://` URLs. Both `curl` and `git ls-remote` support `file://`, so no network is required. Fast and deterministic.
3. **One smoke test against a real GitHub repo** in CI to catch protocol-level regressions in the `raw.githubusercontent.com` and `git ls-remote` interaction. Skipped locally; runs in CI only.

The test harness is itself a justfile (`tests/justfile`) — we dogfood `just` to test the thing.

## 11. Out of scope for v1

- Non-GitHub sources (GitLab, Codeberg, generic git, raw URLs).
- Semver ranges and version solving.
- Transitive dependencies declared by modules.
- Multiple modules per source repo.
- Self-update for `plug.just` itself (`plug update-self`).
- Private repos / authentication. (HTTPS public only; user's git config and `.netrc` may make private repos accidentally work, but it's not designed for or tested.)
- Caching between projects. Each project re-fetches.

These are all reasonable v2 additions that the v1 design does not preclude.
