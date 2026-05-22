# URL-form source support (incl. private repos)

Extends [the original just-plug design](2026-05-15-just-plug-design.md). Adds two new accepted forms of source identifier so that `just plug install` can target private repos (via SSH) and accept the URLs users naturally paste from GitHub or `git remote -v`.

## 1. Motivation

The v1 design accepts one source form, `github.com/<owner>/<repo>`, and fetches files over `raw.githubusercontent.com`. That works for public repos and nothing else. Internal/private modules — the immediate driver here is `Paymentbox-com/just-pbx-wt` — can't be installed today.

Two motivations rolled into one change:

1. **Private repo support.** Switch to a git-based fetch path that respects the user's existing git auth (SSH keys, credential helpers).
2. **URL-form input.** Accept the same URLs `git remote -v` prints, so users can copy-paste without reformatting.

## 2. Accepted source forms

`just plug install <spec>` accepts three input shapes. Each may carry an optional `@<ref>` suffix.

| Input | Stored as | Fetch path |
|---|---|---|
| `github.com/<owner>/<repo>` | `github.com/<owner>/<repo>` | curl `raw.githubusercontent.com` (existing) |
| `https://<host>/<path>/<repo>[.git]` | `https://<host>/<path>/<repo>` | git fetch + cat-file |
| `<user>@<host>:<path>/<repo>[.git]` | `<user>@<host>:<path>/<repo>` | git fetch + cat-file |

Also accepted for testing (and any user who wants it): `file:///path/to/repo[.git]`, treated as the HTTPS URL form.

### Normalization

- Trailing `.git` is stripped.
- Trailing `/` is stripped.
- No other rewriting. The form the user typed (modulo those two suffixes) is the form stored in `just-plug.deps` and `just-plug.lock`.

### Host scope

- **Bare form** stays github.com-only (unchanged from v1).
- **URL forms** accept HTTPS URLs to any host, SSH URLs of the standard `<user>@<host>:<path>` form, and `file://` URLs. The fetch path uses `git` directly, so anything `git clone <url>` can resolve will work. We do not advertise non-GitHub hosts as supported, but we do not artificially block them — and tests rely on `file://` URLs which would otherwise be blocked.

### Module name derivation

Unchanged in principle: take the repo basename (last `/`-separated segment of the stored source, after `.git` stripping), then strip a leading `just-` if present. Applies uniformly across all three forms.

Examples:

| Source | Module name |
|---|---|
| `github.com/foo/just-docker` | `docker` |
| `https://github.com/foo/just-docker.git` | `docker` |
| `git@github.com:Paymentbox-com/just-pbx-wt.git` | `pbx-wt` |
| `file:///tmp/just-fixture.git` | `fixture` |

### Collision rule

Unchanged: collision is by module name, not by source string. If `pbx-wt` is already installed from `git@github.com:Paymentbox-com/just-pbx-wt`, then `just plug install https://github.com/Paymentbox-com/just-pbx-wt.git` (same repo, different form) is rejected with the existing collision error naming the already-installed source. The user must `plug remove` first if they want to switch forms.

## 3. Parsing (`_parse-source`)

### Form detection

Detected by leading characters of the spec:

- starts with `https://` or `file://` → URL form (HTTPS-style)
- starts with `<user>@<host>:` (matched by `^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:`) → URL form (SSH-style)
- otherwise → bare form (existing `^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` validation)

Plain `http://` is not accepted; insist on `https://` for any non-`file://` HTTPS-style URL.

### `@<ref>` extraction

The naive "split on last `@`" used today is unsafe for the new URL forms:

- `git@github.com:owner/repo` has an `@` in the host position, no ref.
- `https://user:pass@host/owner/repo` has an `@` in the userinfo, no ref.

Rule: a literal `@<ref>` suffix only applies to characters **after** the URL's path begins. Per form:

- **Bare**: `@` cannot appear in a valid bare source (regex excludes it), so the existing "split on last `@`" remains correct.
- **SSH** (`<user>@<host>:<path>`): split the spec on the **first** `:` into prefix `<user>@<host>:` and tail `<path>`. Then split the tail on the last `@` to extract `@<ref>` from `<path>`.
- **HTTPS / file** (`<scheme>://<authority>/<path>`): split into scheme, authority, and path. Split the path on the last `@` to extract `@<ref>`. `@` in the authority (userinfo) is preserved.

If no `@<ref>` is found, default to `main` (unchanged).

### Output

`<name> <source> <ref>` on stdout, where `source` is the normalized stored form (no `.git`, no trailing `/`). Unchanged contract for callers.

### Inline parse in `install`

The single-install path in `install` currently re-implements parsing inline to avoid a sub-`just` cwd issue. That inline block must mirror the three-form logic. (We accept this duplication for the same reason as today; the helper exists primarily for testability.)

## 4. URL derivation (`_source-to-url`)

A new private helper, called wherever git operations need a URL:

| Source form | URL git uses |
|---|---|
| Bare `github.com/owner/repo` | `${JUST_PLUG_GIT_BASE:-https://github.com}/owner/repo` |
| HTTPS / file URL form | source as stored (optionally with `.git` appended for cosmetic git compatibility — `git` accepts either) |
| SSH URL form | source as stored |

`JUST_PLUG_GIT_BASE` continues to override only the bare form, matching its existing role as a test escape hatch.

## 5. Ref resolution (`_resolve-ref`)

Today's signature takes a stripped `<owner>/<repo>` and prepends `JUST_PLUG_GIT_BASE`. Change the signature to take the full source string (as stored), and obtain the URL via `_source-to-url`. The 7–40-char hex SHA passthrough is unchanged.

Callers (`install` reconcile mode, `install` single mode, `update`, `outdated`) all stop stripping `github.com/` before calling.

## 6. Fetch (`_fetch`)

Branch on source form:

### Bare form (existing)

```sh
base="${JUST_PLUG_RAW_BASE:-https://raw.githubusercontent.com}"
repo_path="${source#github.com/}"
url="$base/$repo_path/$sha/$filename"
curl -fsSL --max-time 60 -o "$tmp" "$url"
```

Unchanged.

### URL forms (new)

```sh
url="$(_source-to-url "$source")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
git -C "$tmpdir" init -q
git -C "$tmpdir" remote add origin "$url"
git -C "$tmpdir" fetch --depth 1 -q origin "$sha"
git -C "$tmpdir" cat-file -p "$sha:$filename" > "$tmp"
```

GitHub enables `uploadpack.allowReachableSHA1InWant`, so fetching by SHA on a `--depth 1` shallow clone works. For non-GitHub hosts the same flag is widely enabled but not guaranteed; we accept that as a YAGNI risk — bug reports for niche hosts can drive a fallback (e.g., resolve SHA → fetch by ref name) later.

The hashing (`shasum -a 256`) and atomic `mv` to `dest` are identical to the bare path.

## 7. Other call sites

| Site | Change |
|---|---|
| `install` reconcile mode | Stop stripping `github.com/` from `source` before passing to `_resolve-ref` and `_fetch`. |
| `install` single mode | Mirror new parsing logic inline (see §3); same `_resolve-ref` and `_fetch` change. |
| `update` (per module) | Same `_resolve-ref` and `_fetch` change. |
| `outdated` | Replace inline `base/repo_path` URL construction with `_source-to-url`. Tag/branch enumeration via `git ls-remote` is unchanged. |
| `_remove-dep`, `_remove-lock`, `_upsert-*`, `_gen-modules`, `verify`, `list`, `remove` | Unchanged — they operate on names, not sources. |

## 8. Storage formats

`just-plug.deps` and `just-plug.lock` keep their existing whitespace-separated layout:

```
# name      source                                       ref
docker      github.com/foo/just-docker                   v1.2.0
pbx-wt      git@github.com:Paymentbox-com/just-pbx-wt    main
gateway     https://github.com/Paymentbox-com/gateway    v2.0.0
```

URLs contain no whitespace, so awk-on-whitespace parsing still works without quoting. No new columns. Pre-existing files with bare-form sources continue to function unchanged.

## 9. Tests

### Unit (`tests/unit/test_parse.sh`)

Add cases:

- `https://github.com/foo/just-docker` → `docker https://github.com/foo/just-docker main`
- `https://github.com/foo/just-docker.git` → same (.git stripped)
- `https://github.com/foo/just-docker.git@v1.2.0` → `docker https://github.com/foo/just-docker v1.2.0`
- `https://github.com/foo/just-docker@develop` → `docker https://github.com/foo/just-docker develop`
- `git@github.com:foo/just-docker` → `docker git@github.com:foo/just-docker main`
- `git@github.com:foo/just-docker.git` → same (.git stripped)
- `git@github.com:foo/just-docker@v1.2.0` → `docker git@github.com:foo/just-docker v1.2.0`
- `https://user:pass@github.com/foo/just-docker@v1.2.0` → ref correctly `v1.2.0` despite `@` in userinfo
- `file:///tmp/just-fixture` → `fixture file:///tmp/just-fixture main`

Invalid:

- `https://github.com/foo` (missing repo path segment) → rejected
- `git@github.com:foo` (missing repo) → rejected

### Integration

Add `tests/integration/test_install_url.sh` covering the git-fetch path. Set up a local bare git repo at `$TMP/repo.git` containing a sample `<name>.just`, install via `file://$TMP/repo.git`, verify the resulting file matches and lock contains the URL form unchanged.

Existing integration tests (`test_install.sh`, `test_reconcile.sh`, `test_update.sh`, `test_outdated.sh`) continue to exercise the bare form via `JUST_PLUG_GIT_BASE`/`JUST_PLUG_RAW_BASE` overrides — they should not regress.

CI smoke test is unchanged (still hits a public GitHub repo via the bare form). Adding an SSH-form smoke test would require a deploy key in CI and is out of scope here.

## 10. Spec updates to the v1 design

Three concrete changes to `2026-05-15-just-plug-design.md`:

1. **§4 "Source identifier"**: replace the single-form bullet with the three-form table from §2 above. Note URL forms route through git and respect existing git auth.
2. **§8 "Internals" — HTTP fetch / ref resolution**: add the git-fetch path alongside the curl path; describe the GitHub `allowReachableSHA1InWant` dependency.
3. **§11 "Out of scope for v1"**: remove the "Private repos / authentication" bullet (now supported via SSH/URL forms). The other out-of-scope items (GitLab/Codeberg, semver, transitive deps, multi-module repos, self-update, cross-project caching) remain.

## 11. Out of scope (this change)

- Credentials embedded in source URLs (e.g., `https://<token>@github.com/...`). Tokens belong in git credential helpers, not in `.deps`/`.lock` files that get committed.
- Non-GitHub host **support** in the published sense — URL forms work for any host git understands, but we don't test or document non-GitHub usage.
- A migration command that converts existing bare-form entries to URL form.
- `ssh://user@host/path` URL syntax. Standard scp-like `git@host:path` syntax covers the common case; we can add this later if requested.
