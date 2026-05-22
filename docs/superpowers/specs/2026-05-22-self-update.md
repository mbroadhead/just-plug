# `self-update` recipe

Extends [the original just-plug design](2026-05-15-just-plug-design.md) and the [URL-form spec](2026-05-22-url-form-source-support.md). Adds a recipe that updates `plug.just` itself, so users do not have to re-run the bootstrap `curl` command by hand.

## 1. Motivation

`plug.just` is bootstrapped once with a `curl` command from the README and then committed into the user's repo. There is no in-tree way to pull a newer version. Users wanting to upgrade currently re-run the bootstrap (and have to remember the URL), or copy the file out of band. A first-class recipe closes the gap, lets users pin to a release for stability, and lets fork/branch users point at their own copy.

## 2. CLI shape

```
just plug self-update [spec]
```

`spec` is optional. Accepted forms, matching `install` semantics:

| Input | Resolves to |
|---|---|
| *(omitted)* | `github.com/mbroadhead/just-plug@main` |
| `@<ref>` | `github.com/mbroadhead/just-plug@<ref>` |
| `<source>` | `<source>@main` |
| `<source>@<ref>` | as written |

`<source>` accepts any form `install` accepts (bare `github.com/...`, HTTPS URL, SSH URL, `file://`).

## 3. Behavior

1. **Parse spec.** Expand the bare `@<ref>` shorthand into the default source. Reuse `_parse-source` for everything else.
2. **Resolve ref → SHA** via `_resolve-ref`.
3. **Fetch** `plug.just` at that SHA into a temp file via `_fetch` (filename argument: `plug.just`).
4. **Compare** the temp file byte-for-byte against `{{justfile_directory()}}/just-plug/plug.just`.
   - If identical: print `just-plug is up to date at <short-sha>` and exit 0. Remove the temp file.
   - If different: `mv` the temp file over `just-plug/plug.just` (atomic on same filesystem). Print `updated just-plug → <short-sha> (<source>@<ref>)`.

`_fetch` already verifies the fetched blob came from the resolved SHA, so corrupted downloads fail before step 4.

## 4. Target path

The file being replaced is always `{{justfile_directory()}}/just-plug/plug.just`. This matches the layout the README documents and the `PLUGDIR` value emitted by `_paths`. No discovery; no override flag.

## 5. Out of scope

- **Lockfile tracking.** just-plug's own SHA is not recorded in `just-plug.lock`. `verify` and `outdated` continue to cover user modules only.
- **Backup file.** Projects commit `plug.just`; `git checkout just-plug/plug.just` is the documented rollback. No `.bak` sidecar.
- **Signature / GPG verification.** Out of scope for v1, same as `install`.
- **Semver range selection.** Pin by tag, branch, or SHA — same as `install`.
- **Confirmation prompt.** `just` recipes are non-interactive by convention.
- **Initial bootstrap.** `self-update` cannot install just-plug from a clean slate, because invoking `just plug self-update` requires `plug.just` to already exist (otherwise the `plug` module is undefined and the recipe is unreachable). The README `curl` command remains the documented bootstrap.

## 6. Testing

One integration test, modeled on the existing fixture pattern (`tests/integration/test_*.sh` + `tests/lib/fixture.sh`):

1. Build a fixture bare repo named `just-plug` whose `plug.just` is a stub distinct from the real one.
2. Set up a project that has the *real* `plug.just` installed.
3. Run `just plug self-update file:///<fixture>/just-plug@main`.
4. Assert: `just-plug/plug.just` now matches the fixture's stub (i.e., the recipe replaced the file), and stdout contains `updated just-plug →`.
5. Run `self-update` again with the same spec. Assert: file unchanged, stdout contains `up to date`.

Using a `file://` source keeps the test offline, consistent with the rest of the integration suite.

## 7. README

Add a one-liner under Usage:

```sh
# Update just-plug itself (defaults to mbroadhead/just-plug@main).
just plug self-update
just plug self-update @v1.0.0
```
