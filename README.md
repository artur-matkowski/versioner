# versioner

Conventional-commit versioning as a git submodule: a set of dependency-free
POSIX-bash scripts that

- validate commit messages (strict Conventional Commits subset),
- compute a SemVer for **every commit** (pure function of history — no tags
  required),
- generate a per-branch `CHANGELOG.md`,
- automate tagging on the production branch (CI).

Designed to be embedded as a git submodule in any repo and wired into Gitea
Actions (snippets included; the CLI works anywhere).

## How the version is computed

`version(C)` is the fold of commit `C`'s **entire reachable history**,
oldest-first (topological order):

- start at `0.0.0`;
- for each commit whose subject parses as `type(scope)!: subject` with a
  whitelisted type, apply the bump mapped to it with SemVer reset semantics
  (`major` → `M+1.0.0`, `minor` → `M.m+1.0`, `patch` → `M.m.p+1`);
- a breaking commit (`!` marker or `BREAKING CHANGE:` footer) uses the
  `bump.breaking` mapping;
- merge commits, release-bot commits and non-conventional commits never bump
  (they are *ignored*, not rejected — see `ignore_re`).

Consequences:

- the version is deterministic per commit, on any branch;
- tags are **pins, not inputs**: `versioner check-tag vX.Y.Z` verifies a tag
  matches the computed version of its commit;
- promoting work into `release/production` (merge) bumps the production
  version because the merged commits enter its history;
- cherry-picked commits count per pick; rebasing changes hashes but not the
  version.

### Branch suffix

Off-production commits get a strippable prerelease suffix so builds are
traceable:

```
X.Y.Z-<sanitized-branch>.<hash7>     e.g. 1.2.3-feature-test.a1b2c3d
```

- on a production branch (`production_branches`, default
  `release/production`) the version prints bare: `1.2.3`;
- sanitization: strip `strip_prefix` (default `release/`), then every
  non-alphanumeric becomes `-` (SemVer identifiers allow only
  `[0-9A-Za-z-]`; `feature_test` → `feature-test`);
- `versioner version --strip-suffix` drops everything after `X.Y.Z`.

Because the suffix is a SemVer *prerelease*, it sorts **below** the release
version — correct precedence for dev builds.

## Install (host repo)

```sh
git submodule add <versioner-url> versioner
git submodule update --init
./versioner/bin/versioner install     # installs the commit-msg hook
```

The `commit-msg` hook fast-fails malformed messages locally (the message
doesn't exist yet at pre-commit time, so `commit-msg` is the right hook).
Bypass locally with `git commit --no-verify` (the CI gate is the backstop).

## Commands

| Command | Purpose |
|---|---|
| `versioner install` | install the `commit-msg` hook |
| `versioner lint-msg <file>` | validate one message (hook entrypoint) |
| `versioner lint-range <base> <head>` | validate all non-ignored commits in `merge-base(base,head)..head`; per-commit errors; exit 1 on failure |
| `versioner version [commit] [--strip-suffix]` | computed version (default `HEAD`, suffixed off-production) |
| `versioner changelog [ref] [-o file]` | regenerate `CHANGELOG.md` (default `HEAD` → `./CHANGELOG.md`) |
| `versioner release [--push]` | compute version, regenerate changelog, commit `chore(release): vX.Y.Z`, annotated tag; `--push` pushes branch + tag. Idempotent: no-op when the version didn't change. |
| `versioner check-tag <tag>` | verify `tag == version(tagged commit)` |

## Policy and overrides (buildroot-style)

Policy lives in `key=value` conf files. Resolution order, later wins:

1. built-in seed defaults,
2. `versioner/defaults/*.conf` (this submodule),
3. `<parent repo>/external-overrides/*.conf` — **tracked by the parent repo,
   not by this submodule**, exactly like buildroot's `external-overrides/`.
   Override the location with `$VERSIONER_OVERRIDES_DIR`.

Available keys:

| Key | Default | Meaning |
|---|---|---|
| `types` | `feat fix chore docs refactor perf test style ci` | space-separated whitelist; other types fail lint and never bump |
| `bump.<type>` | `feat=minor fix=patch breaking=major`, rest `noop` | bump level per type |
| `ignore_re` | `^Merge`, `^chore(release):`, `^Revert` | append-only EREs on subjects; matched commits skip lint and are ignored by fold/changelog |
| `production_branches` | `release/production` | branches that print bare `X.Y.Z` |
| `strip_prefix` | `release/` | prefix stripped before suffix sanitization |
| `hash_len` | `7` | hash length in suffix |
| `tag_prefix` | `v` | tag prefix |
| `subject_max` | `72` | max subject length |

Example override (`external-overrides/00-policy.conf`, committed in the
parent repo):

```conf
bump.perf=patch
ignore_re=^WIP
production_branches=release/production release/staging
```

## CI (Gitea Actions)

Two snippets in `ci/gitea/`, copy into the host repo's
`.gitea/workflows/`:

- **`pr-gate.yml`** — on every PR, lints only the PR's new commits
  (`merge-base..HEAD`). Legacy history never blocks; force-pushes and
  `--no-verify` commits are caught here.
- **`auto-release.yml`** — on push to `release/production`, runs
  `versioner release --push`: regenerates `CHANGELOG.md`, commits, tags
  `vX.Y.Z`, pushes. Requires a write token (`GITEA_TOKEN`).

Both assume the submodule is checked out at `./versioner`
(`submodules: true` in the checkout step).

### Release model

`main` (development) → promotion merges into `release/feature_test` →
`release/testing` → `release/production`. Any version-relevant commit that
enters `release/production`'s history bumps its computed version; the next
push auto-tags it. Non-bump commits after a tag don't update the changelog
until the next version (same behavior as semantic-release).

## Changelog format

Regenerated whole, newest section first; a commit is grouped under the
version computed *at* that commit (a bump commit opens the new section):

```md
# Changelog

_Generated by versioner on 2026-08-31. ..._

## 1.2.0 - 2026-08-30

- feat: side (9f3ab12)

## 1.0.0 - 2026-08-29

- feat!: c (7c1d9e0) **BREAKING**
```

Non-conventional commits are omitted (the fold ignores them too, so the
changelog and the version always agree).

## Tests

```sh
tests/run.sh            # add KEEP=1 to keep the scratch dir for inspection
```

Dep-free bash harness. One end-to-end workflow: it mirrors this repo to a
bare origin, initializes a dummy parent repo, adds versioner as a real git
submodule, installs the commit-msg hook, then scripts a conventional-commit
history (with the hook active) and asserts on:

- fold / suffix / lint-msg / lint-range / changelog / release idempotency
- the installed hook accepting valid and rejecting invalid messages
- **every policy key** overridden through the parent's tracked
  `external-overrides/` (`types`, `bump.<type>`, `ignore_re`,
  `production_branches`, `strip_prefix`, `hash_len`, `tag_prefix`,
  `subject_max`), including file layering and the
  `VERSIONER_OVERRIDES_DIR` env dir (which replaces, not layers on, the
  default dir)
- a release driven by overridden `tag_prefix`
- a fresh clone of the parent: submodule + parent overrides carried over
- a purity guard: the submodule gitlink and its working tree are never
  modified by any of the above

Known codified gap: the commit-msg hook does **not** honor `ignore_re`
(only `lint-range`, the fold and the changelog do). Scratch dir
`tests/tmp/` is gitignored.

## Notes & caveats

- bash ≥ 4, git ≥ 2.13, GNU-ish userland (grep/sed/tr); no network, no
  external packages.
- The fold is order-sensitive by design (SemVer reset semantics); ordering is
  topological, so parents always apply before children.
- `external-overrides/` must sit one level above the submodule checkout
  (i.e. `<parent>/external-overrides/` when the submodule lives in
  `<parent>/versioner/`).
- Gitea Actions context variable names can differ between Gitea versions;
  the snippets avoid PR-context variables entirely (base branch is a
  workflow env), so they are version-stable.
