# Module name conflicts implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a module be installed under a chosen local name (`--as`), and stop `install` from writing a `modules.just` entry that breaks the user's justfile.

**Architecture:** The local name and the remote entry filename are decoupled. `install` gains an `--as <name>` option via a variadic `*flags` parameter (just passes `--`-prefixed words through to variadic recipe arguments — verified on just 1.47.1). A new `_entry-file` helper derives the remote filename from `source`, so `install` (single + reconcile) and `update` stop passing `<local-name>.just` as the fetch filename. A new `_name-status` helper probes the root justfile with `just --show` / `just --list` and reports `recipe`, `module`, `free`, or `unknown`. Rollback restores file copies rather than calling helper recipes, because a broken justfile cannot be parsed by a sub-`just`.

**Tech Stack:** just (justfile), bash, git, the existing `tests/lib/{fixture,assert}.sh` harness.

---

## File Structure

- **`plug.just`** — two new private helpers (`_entry-file`, `_name-status`), inserted after `_source-to-url`; changes to `install`, `update`.
- **`tests/unit/test_entry_file.sh`** — new; remote-filename derivation across source forms.
- **`tests/integration/test_name_conflicts.sh`** — new; `--as` end to end plus the three rejection cases.
- **`README.md`** — `--as` and the recovery command.

`just-plug.deps` and `just-plug.lock` formats do not change.

---

### Task 1: Failing tests

- [ ] **Step 1:** Write `tests/unit/test_entry_file.sh` covering `github.com/foo/just-docker` → `docker.just`, `github.com/foo/docker` → `docker.just`, `https://github.com/foo/just-docker` → `docker.just`, `git@github.com:foo/just-docker` → `docker.just`, `file:///tmp/x/just-docker` → `docker.just`.
- [ ] **Step 2:** Write `tests/integration/test_name_conflicts.sh` per spec §8.
- [ ] **Step 3:** Run both; confirm they fail on the missing `_entry-file` recipe and the unrecognized `--as`.
- [ ] **Step 4:** Commit as `test: failing tests for module name conflicts and --as`.

---

### Task 2: `_entry-file` helper and its callers

- [ ] **Step 1:** Add `_entry-file source` after `_source-to-url`. Strip a trailing `/`, then `.git`, take the basename, strip a leading `just-`, append `.just`.
- [ ] **Step 2:** In `install` reconcile mode and in `update`'s `update_one`, replace the `"$name.just"` / `"$n.just"` fetch argument with the result of `_entry-file "$source"`.
- [ ] **Step 3:** `bash tests/unit/test_entry_file.sh` passes; `just -f tests/justfile test` shows no regressions.
- [ ] **Step 4:** Commit as `refactor: derive the remote entry filename from the source`.

---

### Task 3: `--as`

- [ ] **Step 1:** Change the signature to `install spec="" *flags:`. Parse `--as <name>` and `--as=<name>`; reject anything else with `error: unknown option: <flag>`; reject `--as` in reconcile mode (empty spec).
- [ ] **Step 2:** Set `name="${alias:-${repo#just-}}"` and use `_entry-file` for the single-install fetch.
- [ ] **Step 3:** Validate the name against `^[a-zA-Z_][a-zA-Z0-9_-]*$` before anything else, with a message naming `--as`.
- [ ] **Step 4:** Alias assertions in the integration test pass.
- [ ] **Step 5:** Commit as `feat: install modules under a chosen name with --as`.

---

### Task 4: Namespace preflight and rollback

- [ ] **Step 1:** Add `_name-status name`: if `just --justfile <root> --summary` fails print `unknown`; else `recipe` if `--show <name>` succeeds, `module` if `--list <name>` succeeds, else `free`.
- [ ] **Step 2:** In single-install mode, call it before fetching. On `recipe` or `module`, error with the `--as` command. On `unknown`, warn and continue. Extend the existing different-source lock check's message with `--as`.
- [ ] **Step 3:** Before mutating state, copy `just-plug.deps`, `just-plug.lock`, `just-plug/modules.just` into a temp dir. After `_gen-modules`, if the pre-status was not `unknown` and the root justfile no longer parses, restore the copies with `cp`, delete the fetched file, print just's parse error plus the `--as` hint, exit 1.
- [ ] **Step 4:** Full suite green.
- [ ] **Step 5:** Commit as `feat: refuse installs that would break the justfile`.

---

### Task 5: README

- [ ] **Step 1:** Under "Module naming", document `--as`, the conflict error, and the `JUST_PLUG_DIR=.. just -f just-plug/plug.just remove <name>` recovery command.
- [ ] **Step 2:** Commit as `docs: document --as and name-conflict recovery`.
