# versioner — instructions for an agent

You are reading this because a repo told you it uses `versioner`, a git
submodule that governs commit messages, version numbers, `CHANGELOG.md` and
release tags. This file is the whole contract; you should not need to read the
source to use it correctly.

**The one rule: never edit anything inside this submodule.** All policy is
overridden from the parent repo's `external-overrides/`. Editing the submodule
makes it impossible to update and the change will be lost on the next
`git submodule update --remote`.

Throughout, `./versioner/` is the conventional checkout path. If the submodule
lives elsewhere in the parent, substitute that path.

## 1. Wiring it into a parent repo

```sh
git submodule add <versioner-url> versioner
git submodule update --init
./versioner/bin/versioner init          # idempotent; --force refreshes files
git add .gitea external-overrides .gitmodules versioner
git commit -m 'ci: wire in versioner'
```

`init` writes **into the parent repo only**:

| Path | What it is |
|---|---|
| `.git/hooks/commit-msg` | rejects malformed messages before the commit lands |
| `.gitea/workflows/versioner-pr-gate.yml` | thin trigger → `./versioner/ci/pr-gate.sh` |
| `.gitea/workflows/versioner-auto-release.yml` | thin trigger → `./versioner/ci/release.sh` |
| `external-overrides/00-policy.conf.example` | policy skeleton, every key commented |

The workflow files are deliberately ~10 lines: **all CI logic lives in
`versioner/ci/*.sh`**, so `git submodule update --remote` ships fixes without
touching the parent. Do not inline that logic into the parent's YAML.

The hook resolves its own path at runtime, so a clone at a different path keeps
working — but each fresh clone must still run `versioner install` (or `init`),
because git never copies hooks.

Then add to the parent's own `CLAUDE.md` / `AGENTS.md`:

> ## Versioning
> Commit messages, versions, `CHANGELOG.md` and release tags in this repo are
> governed by `versioner`, a git submodule at `./versioner`. Read
> `./versioner/AGENTS.md` before changing commit conventions, CI, or anything
> under `external-overrides/`. Commit messages must be Conventional Commits
> (`type(scope)!: subject`); `./versioner/bin/versioner config` prints the
> policy actually in effect.

## 2. Writing commit messages

Grammar (the hook enforces exactly this on the first line):

```
type(scope)!: subject
```

- `type` — lowercase, must be in `types`. Default set: `feat fix chore docs
  refactor perf test style ci build revert`.
- `(scope)` — optional, `[A-Za-z0-9._-]+`.
- `!` — optional breaking marker. `BREAKING CHANGE:` or `BREAKING-CHANGE:` at
  the **start of a line** in the body does the same thing.
- `: ` — colon **and a space**, both required.
- `subject` — non-empty, ≤ `subject_max` (default 72), no trailing period.

Do not guess the allowed types — run `./versioner/bin/versioner config`.

Subjects matching `ignore_re` (default: `^Merge`, `^chore\(release\):`,
`^Revert`) are exempt everywhere: the hook, the PR gate, the version fold and
the changelog all consult the same list. So `git merge` and `git revert` work
normally; you do **not** need `--no-verify` for them. If you find yourself
reaching for `--no-verify`, the message is genuinely wrong — fix the message.

## 3. Commands

| Command | Purpose |
|---|---|
| `versioner init [--force]` | wire versioner into the surrounding repo |
| `versioner install [--force]` | install the `commit-msg` hook only |
| `versioner lint-msg <file>` | validate one message file (the hook's entrypoint) |
| `versioner lint-range <base> [head]` | validate every non-ignored commit in `merge-base(base,head)..head` |
| `versioner version [commit] [--strip-suffix] [--branch <n>] [--json]` | computed version |
| `versioner changelog [ref] [-o file]` | regenerate `CHANGELOG.md` |
| `versioner release [--push] [--any-branch]` | changelog + release commit + annotated tag |
| `versioner check-tag <tag> [--json]` | verify a tag matches its commit's computed version |
| `versioner config [--json]` | the effective policy and where each key came from |

**Exit codes** — rely on these, not on parsing output:

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | policy failure: lint failed, or a tag does not match its commit |
| `2` | usage or configuration error: bad flag, unknown ref, invalid policy, refused release |

`--json` on `version`, `check-tag` and `config` gives machine-readable output.

## 4. How the version is computed

`version(C)` is a fold over `C`'s entire reachable history, oldest first
(topological order), starting at `0.0.0`. Each conventional commit applies the
bump mapped to its type with SemVer reset semantics (`major` → `M+1.0.0`,
`minor` → `M.m+1.0`, `patch` → `M.m.p+1`). Merge commits, release commits,
`ignore_re` matches, non-conventional commits and unknown types never bump.

Consequences you must not get wrong:

- **No tags are read.** Tags are pins you can verify with `check-tag`, never
  inputs. Deleting a tag does not change any version.
- **`X.Y.Z` is a pure function of the commit** — the same commit computes the
  same version on any branch, in any checkout.
- **The `-suffix` is not.** It reflects checkout context: off a production
  branch you get `X.Y.Z-<sanitized-branch>.<hash>`, which sorts *below*
  `X.Y.Z` as a SemVer prerelease. Branch resolution, first hit wins:
  `--branch` / `$VERSIONER_BRANCH` → `$GITEA_REF_NAME` / `$GITHUB_REF_NAME` /
  `$CI_COMMIT_BRANCH` → the checked-out branch → a branch containing the commit
  → `detached`. **In CI, which checks out a detached HEAD, set the branch
  explicitly or rely on the CI ref name.** Use `--strip-suffix` when you want
  the bare number.
- Merging a branch adds its commits to the target's history, so promotion
  merges bump the target. Cherry-picks count once per pick.
- The fold is order-sensitive (resets), so reordering commits across a merge
  can change the result. A plain rebase that preserves order does not.

## 5. Changing policy

Policy is `key=value` files. Resolution order, later wins:

1. `versioner/defaults/*.conf` (shipped; **do not edit**)
2. `<parent>/external-overrides/*.conf` (alphabetical; tracked by the parent)

`$VERSIONER_OVERRIDES_DIR` **replaces** step 2 rather than layering on it.

| Key | Default | Meaning |
|---|---|---|
| `types` | `feat fix chore docs refactor perf test style ci build revert` | allowed types; anything else fails lint and never bumps |
| `bump.<type>` | `feat=minor fix=patch breaking=major`, rest `noop` | bump level per type; `bump.breaking` covers `!` and the footer |
| `ignore_re` | `^Merge`, `^chore\(release\):`, `^Revert` | ERE per line, appended; a bare `ignore_re=` resets the list |
| `production_branches` | `release/production` | branches that print a bare `X.Y.Z` |
| `strip_prefix` | `release/` | stripped from the branch name before sanitizing the suffix |
| `hash_len` | `7` | hash length in the suffix and the changelog (4–40) |
| `tag_prefix` | `v` | prefix for version tags |
| `subject_max` | `72` | max subject length |

Invalid values are a hard error (exit 2) naming the file and key — a typo like
`bump.feat=Minor` will not silently disable the bump. An unknown key warns and
is skipped. A conf file can only set the keys above; it can never assign an
arbitrary shell variable.

Example `external-overrides/00-policy.conf`:

```conf
bump.perf=patch
ignore_re=^WIP
production_branches=release/production release/staging
```

## 6. Release flow

`main` → merge into `release/feature_test` → `release/testing` →
`release/production`. Any version-relevant commit entering
`release/production`'s history bumps its computed version; the push triggers
`ci/release.sh`, which regenerates `CHANGELOG.md`, commits
`chore(release): vX.Y.Z`, creates the annotated tag and pushes both.

`release` refuses to run — exit 2, nothing written — when HEAD is detached,
when the branch is not in `production_branches` (pass `--any-branch` to
override), when the index has staged changes, or when the tag it would create
already exists elsewhere. It is idempotent: if the version has not changed it
prints `up to date` and stops. `ci/release.sh` re-attaches CI's detached HEAD
to the pushed branch before calling it.

## 7. Working on versioner itself

```sh
tests/run.sh            # unit + e2e + shellcheck;  KEEP=1 keeps tests/tmp/
tests/run.sh unit       # fast: pure functions, no git
VERBOSE=1 FILTER=release tests/run.sh e2e
```

The e2e suite snapshots the **working tree** into a bare remote and wires that
in as a real submodule of a throwaway parent repo, so uncommitted edits are
what gets tested. If you change how the fixture is built, keep that property —
cloning this repo directly tests the last commit instead, and a broken edit
will still look green.

Every scenario builds its own host repo. Do not add cross-scenario state.
