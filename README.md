# versioner

Conventional-commit versioning as a git submodule: a set of dependency-free
bash scripts that

- validate commit messages (strict Conventional Commits subset),
- compute a SemVer for **every commit** (pure function of history — no tags
  required),
- generate a per-branch `CHANGELOG.md`,
- automate tagging on the production branch (CI).

Designed to be embedded as a git submodule in any repo and wired into Gitea
Actions (thin workflow stubs included; the CLI works anywhere).

Agents: read [AGENTS.md](AGENTS.md) instead — it is the operational contract.

## Install (host repo)

```sh
git submodule add <versioner-url> versioner
git submodule update --init
./versioner/bin/versioner init
git add .gitea external-overrides .gitmodules versioner
git commit -m 'ci: wire in versioner'
```

`init` is idempotent and writes into the host repo only: the `commit-msg` hook,
two thin CI workflow stubs, and an `external-overrides/` policy skeleton. Use
`versioner install` if you only want the hook. Hooks are never cloned, so each
fresh clone needs one `versioner install` (or `init`) run.

The `commit-msg` hook fast-fails malformed messages locally (the message does
not exist yet at pre-commit time, so `commit-msg` is the right hook). It
resolves its own path at runtime, so moving or re-cloning the repo does not
break it, and an existing third-party `commit-msg` hook is backed up to
`commit-msg.pre-versioner` rather than overwritten.

## Commands

| Command | Purpose |
|---|---|
| `versioner init [--force]` | wire versioner into the surrounding repo |
| `versioner install [--force]` | install the `commit-msg` hook |
| `versioner lint-msg <file>` | validate one message (hook entrypoint) |
| `versioner lint-range <base> [head]` | validate all non-ignored commits in `merge-base(base,head)..head` |
| `versioner version [commit] [--strip-suffix] [--branch <n>] [--json]` | computed version (default `HEAD`) |
| `versioner changelog [ref] [-o file]` | regenerate `CHANGELOG.md` |
| `versioner release [--push] [--any-branch]` | changelog + release commit + annotated tag |
| `versioner check-tag <tag> [--json]` | verify `tag == version(tagged commit)` |
| `versioner config [--json]` | effective policy and where each key came from |

Exit codes: `0` success · `1` policy failure (lint failed, tag mismatch) ·
`2` usage or configuration error (bad flag, unknown ref, invalid policy,
refused release).

## How the version is computed

`version(C)` is the fold of commit `C`'s **entire reachable history**,
oldest-first (topological order):

- start at `0.0.0`;
- for each commit whose subject parses as `type(scope)!: subject` with a
  whitelisted type, apply the bump mapped to it with SemVer reset semantics
  (`major` → `M+1.0.0`, `minor` → `M.m+1.0`, `patch` → `M.m.p+1`);
- a breaking commit (`!` marker, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:`
  footer at the start of a line) uses the `bump.breaking` mapping;
- merge commits, release commits, `ignore_re` matches, unknown types and
  non-conventional commits never bump (they are *ignored*, not rejected).

Consequences:

- the bare `X.Y.Z` is deterministic per commit, on any branch, in any checkout;
- tags are **pins, not inputs**: `versioner check-tag vX.Y.Z` verifies a tag
  matches the computed version of its commit, and deleting a tag changes
  nothing;
- promoting work into `release/production` (merge) bumps the production
  version because the merged commits enter its history;
- cherry-picked commits count per pick;
- the fold is order-sensitive by design (SemVer reset semantics). A plain
  rebase that preserves commit order preserves the version; reordering commits
  relative to a merged branch can change it.

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

Unlike `X.Y.Z`, the suffix depends on checkout context. Branch resolution,
first hit wins:

1. `--branch <name>` or `$VERSIONER_BRANCH`
2. `$GITEA_REF_NAME`, `$GITHUB_REF_NAME`, `$CI_COMMIT_BRANCH`
3. the checked-out branch
4. a branch that contains the commit
5. the literal `detached`

Step 2 matters: CI checks out a detached HEAD, and without it every CI build
would be labelled `detached`.

## Policy and overrides (buildroot-style)

Policy lives in `key=value` conf files. Resolution order, later wins:

1. `versioner/defaults/*.conf` — shipped with this submodule, the single
   source of the defaults; do not edit them in a host repo,
2. `<parent repo>/external-overrides/*.conf` — **tracked by the parent repo,
   not by this submodule**, exactly like buildroot's `external-overrides/`.
   `$VERSIONER_OVERRIDES_DIR` replaces this directory rather than layering on
   it.

Available keys:

| Key | Default | Meaning |
|---|---|---|
| `types` | `feat fix chore docs refactor perf test style ci build revert` | space-separated whitelist; other types fail lint and never bump |
| `bump.<type>` | `feat=minor fix=patch breaking=major`, rest `noop` | bump level per type |
| `ignore_re` | `^Merge`, `^chore\(release\):`, `^Revert` | one ERE per line, appended; a bare `ignore_re=` resets the list |
| `production_branches` | `release/production` | branches that print bare `X.Y.Z` |
| `strip_prefix` | `release/` | prefix stripped before suffix sanitization |
| `hash_len` | `7` | hash length in the suffix and changelog (4–40) |
| `tag_prefix` | `v` | tag prefix |
| `subject_max` | `72` | max subject length |

A conf file can set only these keys; anything else warns and is skipped, so a
policy file can never assign an arbitrary shell variable. Invalid values
(`bump.feat=Minor`, `hash_len=abc`, empty `types`) are a hard error naming the
file and key, rather than a silently wrong version. `versioner config` prints
what is actually in effect.

Example override (`external-overrides/00-policy.conf`, committed in the
parent repo):

```conf
bump.perf=patch
ignore_re=^WIP
production_branches=release/production release/staging
```

## CI (Gitea Actions)

`versioner init` writes two workflow stubs into the host repo. They are thin on
purpose — trigger, checkout, one `run:` line — because **all CI logic lives in
this submodule**, in `ci/pr-gate.sh` and `ci/release.sh`. Updating the
submodule therefore updates the CI behaviour with no change in the parent repo.
Both scripts also run locally.

- **`ci/pr-gate.sh`** — lints only the PR's new commits (`merge-base..HEAD`),
  so a repo that adopts versioner mid-history is never blocked by legacy
  commits. The base branch comes from the CI's PR base ref, else
  `$VERSIONER_BASE_BRANCH`, else the remote's default branch.
- **`ci/release.sh`** — re-attaches CI's detached HEAD to the pushed branch,
  then runs `versioner release --push`. Requires a token with write access
  (`GITEA_TOKEN`).

Both workflow stubs assume the submodule is checked out (`submodules: true`).

### Release model

`main` (development) → promotion merges into `release/feature_test` →
`release/testing` → `release/production`. Any version-relevant commit that
enters `release/production`'s history bumps its computed version; the next
push auto-tags it. Non-bump commits after a tag don't update the changelog
until the next version (same behaviour as semantic-release).

`release` refuses to run — exit 2, nothing written — on a detached HEAD, on a
branch outside `production_branches` (unless `--any-branch`), with staged
changes in the index, or when the tag it would create already exists on
another line of history. It is idempotent: unchanged version, no-op.

## Changelog format

Regenerated whole, newest section first; a commit is grouped under the
version computed *at* that commit (a bump commit opens the new section):

```md
# Changelog

_Generated by versioner on 2026-08-31. Conventional commits only; do not edit by hand._

## 1.2.0 - 2026-08-30

- feat: side (9f3ab12)

## 1.0.0 - 2026-08-29

- feat!: c (7c1d9e0) **BREAKING**
```

Non-conventional and ignored commits are omitted (the fold ignores them too, so
the changelog and the version always agree).

## Tests

```sh
tests/run.sh            # unit + e2e + shellcheck  (KEEP=1 keeps tests/tmp/)
tests/run.sh unit       # pure functions, no git, fast
VERBOSE=1 FILTER=release tests/run.sh e2e
```

Dep-free bash harness, two layers:

- **`tests/unit.sh`** — the pure functions with no git at all: the header
  grammar, bump parsing (including the `BREAKING CHANGE:` footer), branch
  sanitization, and the config loader's acceptance and rejection rules.
- **`tests/e2e.sh`** — a real parent repo with versioner wired in as a real
  submodule and the hook installed: fold, suffix, lint, changelog (including
  hash formatting), every policy key overridden through the parent's tracked
  `external-overrides/`, file layering and `$VERSIONER_OVERRIDES_DIR`, release
  and its guards, `release --push` to a bare remote, `init`, hook-backup
  safety, the CI scripts under faked CI environments, a fresh clone, and a
  purity guard proving the submodule gitlink and worktree are never modified.

The e2e suite snapshots the **working tree** into the bare remote it wires in,
so uncommitted edits are what gets tested. Each scenario builds its own host
repo, so no scenario can shift another's versions or hashes.

`.gitea/workflows/tests.yml` runs the suite plus `shellcheck` on every push,
and lints versioner's own commits with versioner.

## Notes & caveats

- bash ≥ 4.2, git ≥ 2.13, GNU-ish userland (grep/sed/tr); no network, no
  external packages.
- Ordering is topological, so parents always apply before children.
- `external-overrides/` sits at the root of the parent repo (i.e.
  `<parent>/external-overrides/` when the submodule lives in
  `<parent>/versioner/`).
- The hook resolves the submodule through `git rev-parse --show-toplevel`; in a
  linked worktree the submodule must be checked out there too.
- Gitea Actions context variable names differ between Gitea versions; the
  stubs pass no PR-context variables, and `ci/pr-gate.sh` falls back through
  several conventions, so they are version-stable.
