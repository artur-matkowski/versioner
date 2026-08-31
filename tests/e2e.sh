#!/usr/bin/env bash
# End-to-end tests: a real parent repo with versioner wired in as a real git
# submodule, exercising the CLI, the installed hook and the CI scripts.
#
# Every scenario builds its own host repo, so no scenario can shift another's
# versions or commit hashes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

WORK="${WORK:?WORK must be set}"

# ---------------------------------------------------------------- wiring
if section 'wiring'; then
	new_host wiring
	assert_eq 'submodule registered at versioner/' 'versioner' \
		"$(git -C "$HOST" config -f .gitmodules submodule.versioner.path)"
	assert_true 'submodule binary is executable' test -x "$HOST/versioner/bin/versioner"
	assert_true 'hook installed and executable' test -x "$HOST/.git/hooks/commit-msg"
	assert_contains 'hook is marked as ours' 'Managed by versioner' "$(cat "$HOST/.git/hooks/commit-msg")"
	assert_contains 'hook path is repo-relative, so a moved clone still works' \
		'VERSIONER_BIN="versioner/bin/versioner"' "$(cat "$HOST/.git/hooks/commit-msg")"
	assert_not_contains 'hook does not hardcode an absolute path' "$HOST" \
		"$(sed -n '/VERSIONER_BIN=/p' "$HOST/.git/hooks/commit-msg")"
	assert_eq 'install is idempotent' 0 "$(hvrc install)"
	assert_gitlink_unchanged
	assert_submodule_clean
fi

# ---------------------------------------------------------------- fold
if section 'fold'; then
	new_host fold
	hc 'chore: app scaffold'; C1="$(hrev)"
	hc 'feat: a'; C2="$(hrev)"
	hc 'fix: b'; C3="$(hrev)"
	hc 'feat!: c'; C4="$(hrev)"
	hc 'docs: d'; C5="$(hrev)"
	hc 'feat(x): e'; C6="$(hrev)"
	git -C "$HOST" checkout -q -b side
	hc 'feat: side'
	git -C "$HOST" checkout -q main
	git -C "$HOST" merge -q --no-ff side -m "Merge branch 'side'"
	C7="$(hrev)"
	hc_nv 'bad message'
	C8="$(hrev)"
	hc "$(printf 'fix: with footer\n\nBREAKING CHANGE: the api is gone\n')"
	C9="$(hrev)"

	assert_eq 'chore does not bump' '0.0.0' "$(hv version "$C1" --strip-suffix)"
	assert_eq 'feat -> 0.1.0' '0.1.0' "$(hv version "$C2" --strip-suffix)"
	assert_eq 'fix -> 0.1.1' '0.1.1' "$(hv version "$C3" --strip-suffix)"
	assert_eq 'feat! -> 1.0.0' '1.0.0' "$(hv version "$C4" --strip-suffix)"
	assert_eq 'docs is noop' '1.0.0' "$(hv version "$C5" --strip-suffix)"
	assert_eq 'scoped feat -> 1.1.0' '1.1.0' "$(hv version "$C6" --strip-suffix)"
	assert_eq 'merged branch commits count once' '1.2.0' "$(hv version "$C7" --strip-suffix)"
	assert_eq 'non-conventional commit ignored' '1.2.0' "$(hv version "$C8" --strip-suffix)"
	assert_eq 'BREAKING CHANGE footer -> major' '2.0.0' "$(hv version "$C9" --strip-suffix)"
	assert_eq 'version is stable when recomputed' '1.1.0' "$(hv version "$C6" --strip-suffix)"
	assert_eq 'default commit is HEAD' "$(hv version HEAD --strip-suffix)" "$(hv version --strip-suffix)"
	assert_exit 'unknown commit fails' 1 "$(hvrc version deadbeef)"
fi

# ---------------------------------------------------------------- suffix
if section 'suffix'; then
	new_host suffix
	hc 'feat: a'
	hc 'fix: b'
	BASE="$(hv version --strip-suffix)"
	assert_eq 'base version' '0.1.1' "$BASE"
	assert_eq 'main is suffixed' "0.1.1-main.$(hshort)" "$(hv version)"
	git -C "$HOST" checkout -q -b release/feature_test
	assert_eq 'strip_prefix + sanitization' "0.1.1-feature-test.$(hshort)" "$(hv version)"
	git -C "$HOST" checkout -q -b release/production
	assert_eq 'production prints bare' '0.1.1' "$(hv version)"
	git -C "$HOST" checkout -q main
	assert_eq '--strip-suffix drops the suffix' '0.1.1' "$(hv version --strip-suffix)"
	assert_eq '--branch overrides the checkout' '0.1.1' "$(hv version --branch release/production)"
	assert_eq '--branch also works off production' "0.1.1-x.$(hshort)" "$(hv version --branch x)"
	assert_exit '--branch without a value is a usage error' 2 "$(hvrc version --branch)"
	# a detached checkout is what CI does: fall back to a branch containing the
	# commit, and let the CI ref name win when it is set
	git -C "$HOST" checkout -q --detach HEAD
	assert_eq 'detached HEAD resolves to a containing branch' "0.1.1-main.$(hshort)" "$(hv version)"
	assert_eq 'CI ref name wins on a detached HEAD' '0.1.1' \
		"$( (cd "$HOST" && GITEA_REF_NAME=release/production ./versioner/bin/versioner version 2>&1) )"
	assert_eq 'GITHUB_REF_NAME is honoured too' '0.1.1' \
		"$( (cd "$HOST" && GITHUB_REF_NAME=release/production ./versioner/bin/versioner version 2>&1) )"
	git -C "$HOST" checkout -q main
	OUT="$(hv version --json)"
	assert_contains 'json version' "\"version\":\"0.1.1-main.$(hshort)\"" "$OUT"
	assert_contains 'json base' '"base":"0.1.1"' "$OUT"
	assert_contains 'json branch' '"branch":"main"' "$OUT"
	assert_contains 'json production flag' '"production":false' "$OUT"
fi

# ---------------------------------------------------------------- hook
if section 'hook'; then
	new_host hook
	if hc 'feat: a'; then ok 'hook accepts a valid message'; else fail 'hook accepts a valid message'; fi
	if git -C "$HOST" commit --allow-empty -q -m 'bad message' 2>"$WORK/hook.err"; then
		fail 'hook rejects a non-conventional message' 'commit succeeded'
	else
		ok 'hook rejects a non-conventional message'
	fi
	assert_contains 'hook explains the failure' 'invalid header' "$(cat "$WORK/hook.err")"
	if git -C "$HOST" commit --allow-empty -q -m 'hotfix: h' 2>"$WORK/hook2.err"; then
		fail 'hook rejects an unknown type' 'commit succeeded'
	else
		ok 'hook rejects an unknown type'
	fi
	assert_contains 'hook names the unknown type' 'unknown type' "$(cat "$WORK/hook2.err")"
	# the whole point of ignore_re reaching the hook: promotion merges work
	git -C "$HOST" checkout -q -b side
	hc 'feat: side'
	git -C "$HOST" checkout -q main
	if git -C "$HOST" merge -q --no-ff side -m "Merge branch 'side'" 2>"$WORK/merge.err"; then
		ok 'a promotion merge is not rejected by the hook'
	else
		fail 'a promotion merge is not rejected by the hook' "$(cat "$WORK/merge.err")"
	fi
	if git -C "$HOST" commit --allow-empty -q -m 'Revert "feat: side"' 2>/dev/null; then
		ok 'a revert message is not rejected by the hook'
	else
		fail 'a revert message is not rejected by the hook'
	fi
	if git -C "$HOST" commit --allow-empty -q -m 'chore(release): v9.9.9' 2>/dev/null; then
		ok 'a release commit is not rejected by the hook'
	else
		fail 'a release commit is not rejected by the hook'
	fi
	# ignore_re is policy, so an override reaches the hook as well
	ov_write '10-ignore.conf' 'ignore_re=^WIP'
	if git -C "$HOST" commit --allow-empty -q -m 'WIP: still cooking' 2>/dev/null; then
		ok 'an overridden ignore_re reaches the hook'
	else
		fail 'an overridden ignore_re reaches the hook'
	fi
	ov_reset
	printf 'feat: from a file\n\nbody\n' >"$WORK/msg.txt"
	assert_exit 'lint-msg accepts a valid file' 0 "$(hvrc lint-msg "$WORK/msg.txt")"
	printf '\r\n' >"$WORK/msg.txt"
	assert_exit 'lint-msg rejects a blank message' 1 "$(hvrc lint-msg "$WORK/msg.txt")"
	printf '# just a comment\n' >"$WORK/msg.txt"
	assert_exit 'lint-msg rejects a comment-only message' 1 "$(hvrc lint-msg "$WORK/msg.txt")"
	printf 'feat: crlf message\r\n' >"$WORK/msg.txt"
	assert_exit 'lint-msg tolerates CRLF' 0 "$(hvrc lint-msg "$WORK/msg.txt")"
	assert_exit 'lint-msg without a file is a usage error' 2 "$(hvrc lint-msg)"
	assert_gitlink_unchanged
	assert_submodule_clean
fi

# ---------------------------------------------------------------- lint-range
if section 'lint-range'; then
	new_host lintrange
	hc 'feat: a'; A="$(hrev)"
	hc 'fix: b'; B="$(hrev)"
	assert_exit 'a clean range passes' 0 "$(hvrc lint-range "$A" "$B")"
	assert_exit 'an empty range passes' 0 "$(hvrc lint-range "$B" "$B")"
	hc_nv 'totally invalid'
	BAD="$(hrev)"
	assert_exit 'a bad commit fails the range' 1 "$(hvrc lint-range "$A" "$BAD")"
	OUT="$(hv lint-range "$A" "$BAD")"
	assert_contains 'the failure names the problem' 'invalid header' "$OUT"
	assert_contains 'the failure names the commit' "${BAD:0:7}" "$OUT"
	git -C "$HOST" checkout -q -b side "$A"
	hc 'feat: only mine'
	assert_exit 'merge-base scoping ignores commits outside the branch' 0 "$(hvrc lint-range main HEAD)"
	git -C "$HOST" checkout -q main
	assert_exit 'an unknown base is a usage error' 2 "$(hvrc lint-range nosuchref HEAD)"
	assert_exit 'an unknown head is a usage error' 2 "$(hvrc lint-range main nosuchref)"
	assert_exit 'head defaults to HEAD' 1 "$(hvrc lint-range "$A")"
fi

# ---------------------------------------------------------------- changelog
if section 'changelog'; then
	new_host changelog
	hc 'chore: scaffold'
	hc 'feat: a'
	hc 'fix: b'
	hc 'feat!: c'
	hc 'feat(x): e'
	hc_nv 'not conventional'
	CL="$WORK/cl.md"
	hv changelog HEAD -o "$CL" >/dev/null
	BODY="$(cat "$CL")"
	assert_eq 'sections are newest first' "$(printf '1.1.0\n1.0.0\n0.1.1\n0.1.0\n0.0.0')" \
		"$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$CL")"
	assert_contains 'breaking commits are marked' '**BREAKING**' "$BODY"
	assert_contains 'scopes are kept' 'feat(x): e' "$BODY"
	assert_not_contains 'non-conventional commits are omitted' 'not conventional' "$BODY"
	# every entry must carry a clean 7-char hash: the record split used to leak
	# git's separator newline into the sha of every commit but the first
	ENTRIES="$(grep -c '^- ' "$CL")"
	HASHES="$(grep -cE '^- [a-z]+(\([^)]*\))?: .* \([0-9a-f]{7}\)( \*\*BREAKING\*\*)?$' "$CL")"
	assert_eq 'every entry ends in a clean 7-char hash' "$ENTRIES" "$HASHES"
	assert_not_matches 'no entry contains a stray newline' '\($' "$BODY"
	# 5 above plus the two chore commits every host starts with
	assert_eq 'entry count matches the conventional commits' '7' "$ENTRIES"
	ov_write '10-hash.conf' 'hash_len=10'
	hv changelog HEAD -o "$CL" >/dev/null
	assert_eq 'hash_len override reaches the changelog' "$ENTRIES" \
		"$(grep -cE '\([0-9a-f]{10}\)( \*\*BREAKING\*\*)?$' "$CL")"
	ov_reset
	assert_exit 'changelog rejects an unknown ref' 1 "$(hvrc changelog nosuchref -o "$CL")"
	assert_exit 'changelog rejects a second ref' 2 "$(hvrc changelog HEAD main -o "$CL")"
	assert_exit 'changelog rejects -o without a value' 2 "$(hvrc changelog HEAD -o)"
	hv changelog -o "$WORK/cl2.md" >/dev/null
	assert_true 'ref defaults to HEAD' test -s "$WORK/cl2.md"
fi

# ---------------------------------------------------------------- overrides
if section 'overrides'; then
	new_host overrides
	hc 'feat: a'
	C_A="$(hrev)"
	hc 'perf: p'
	hc 'feat(x): e'
	assert_eq 'baseline' '0.2.0' "$(hv version --strip-suffix)"

	ov_write '10-feat.conf' 'bump.feat=patch'
	assert_eq 'bump.<type> override' '0.0.2' "$(hv version --strip-suffix)"
	ov_reset
	ov_write '10-perf.conf' 'bump.perf=minor'
	assert_eq 'a noop type can be made to bump' '0.3.0' "$(hv version --strip-suffix)"
	ov_reset
	ov_write '10-types.conf' "$(printf 'types=feat fix chore hotfix\nbump.hotfix=patch')"
	hc 'hotfix: h'
	assert_eq 'a new type is accepted by the hook and bumps' '0.2.1' "$(hv version --strip-suffix)"
	assert_exit 'a type dropped from the whitelist fails lint-range' 1 "$(hvrc lint-range "$C_A" HEAD)"
	assert_contains 'and lint-range says which type' 'unknown type "perf"' "$(hv lint-range "$C_A" HEAD)"
	ov_reset
	git -C "$HOST" reset -q --hard HEAD~1

	ov_write '10-ignore.conf' 'ignore_re=^feat\(x\)'
	assert_eq 'ignore_re removes a commit from the fold' '0.1.0' "$(hv version --strip-suffix)"
	hv changelog HEAD -o "$WORK/cl-ov.md" >/dev/null
	assert_not_contains 'ignore_re removes it from the changelog too' 'feat(x): e' "$(cat "$WORK/cl-ov.md")"
	ov_reset

	ov_write '10-prod.conf' 'production_branches=main'
	assert_eq 'production_branches override' '0.2.0' "$(hv version)"
	ov_reset
	git -C "$HOST" checkout -q -b release/staging
	assert_eq 'default strip_prefix' "0.2.0-staging.$(hshort)" "$(hv version)"
	ov_write '10-strip.conf' 'strip_prefix='
	assert_eq 'empty strip_prefix keeps the full branch name' "0.2.0-release-staging.$(hshort)" "$(hv version)"
	ov_write '10-strip.conf' 'strip_prefix=release/st'
	assert_eq 'a custom strip_prefix applies' "0.2.0-aging.$(hshort)" "$(hv version)"
	ov_reset
	git -C "$HOST" checkout -q main
	ov_write '10-hash.conf' 'hash_len=9'
	assert_matches 'hash_len override' '^0\.2\.0-main\.[0-9a-f]{9}$' "$(hv version)"
	ov_reset
	ov_write '10-subj.conf' 'subject_max=100'
	printf 'feat: %s\n' "$(printf 'x%.0s' $(seq 1 80))" >"$WORK/long.txt"
	assert_exit 'subject_max override allows a longer subject' 0 "$(hvrc lint-msg "$WORK/long.txt")"
	ov_reset
	assert_exit 'and the default rejects it again' 1 "$(hvrc lint-msg "$WORK/long.txt")"

	ov_write '10-a.conf' 'bump.fix=major'
	ov_write '20-b.conf' 'bump.feat=patch'
	assert_eq 'multiple override files all apply' '0.0.2' "$(hv version --strip-suffix)"
	ov_reset

	ENV_OV="$WORK/env-overrides"
	mkdir -p "$ENV_OV"
	printf 'bump.feat=patch\n' >"$ENV_OV/00-env.conf"
	assert_eq 'VERSIONER_OVERRIDES_DIR applies' '0.0.2' \
		"$( (cd "$HOST" && VERSIONER_OVERRIDES_DIR="$ENV_OV" ./versioner/bin/versioner version --strip-suffix 2>&1) )"
	ov_write '10-feat.conf' 'bump.feat=major'
	assert_eq 'the env dir REPLACES the parent dir, it does not layer on it' '0.0.2' \
		"$( (cd "$HOST" && VERSIONER_OVERRIDES_DIR="$ENV_OV" ./versioner/bin/versioner version --strip-suffix 2>&1) )"
	assert_eq 'without the env var the parent dir is used again' '2.0.0' "$(hv version --strip-suffix)"
	ov_reset
	assert_gitlink_unchanged
	assert_submodule_clean
fi

# ---------------------------------------------------------------- release
if section 'release'; then
	new_host release
	hc 'feat: a'
	hc 'fix: b'
	git -C "$HOST" checkout -q -b release/production
	assert_exit 'release on the production branch' 0 "$(hvrc release)"
	assert_true 'release wrote CHANGELOG.md' test -f "$HOST/CHANGELOG.md"
	assert_eq 'release commit subject' 'chore(release): v0.1.1' "$(git -C "$HOST" log -1 --format=%s)"
	assert_eq 'tag created' 'v0.1.1' "$(git -C "$HOST" tag --list 'v*')"
	assert_true 'the tag is annotated' git -C "$HOST" rev-parse 'v0.1.1^{tag}'
	assert_eq 'the release commit does not change the version' '0.1.1' "$(hv version --strip-suffix)"
	assert_exit 'check-tag verifies the tag' 0 "$(hvrc check-tag v0.1.1)"
	OUT="$(hv check-tag v0.1.1 --json)"
	assert_contains 'check-tag json ok' '"ok":true' "$OUT"
	AT="$(hrev)"
	assert_exit 'release is idempotent' 0 "$(hvrc release)"
	assert_eq 'idempotent release adds no commit' "$AT" "$(hrev)"
	assert_contains 'idempotent release says so' 'up to date' "$(hv release)"
	hc 'feat: more'
	assert_exit 'a new version releases again' 0 "$(hvrc release)"
	assert_eq 'the new tag exists' "$(printf 'v0.1.1\nv0.2.0')" "$(git -C "$HOST" tag --list 'v*' | sort -V)"
	git -C "$HOST" tag v9.9.9 HEAD
	assert_exit 'check-tag catches a lying tag' 1 "$(hvrc check-tag v9.9.9)"
	assert_contains 'and says what it computed' 'MISMATCH' "$(hv check-tag v9.9.9)"
	assert_exit 'check-tag on a missing tag is a usage error' 2 "$(hvrc check-tag v1.2.3)"
	ov_write '10-tag.conf' 'tag_prefix=rel-'
	hc 'fix: after prefix change'
	assert_exit 'release honours a tag_prefix override' 0 "$(hvrc release)"
	assert_eq 'release commit uses the overridden prefix' 'chore(release): rel-0.2.1' \
		"$(git -C "$HOST" log -1 --format=%s)"
	assert_exit 'check-tag honours the override' 0 "$(hvrc check-tag rel-0.2.1)"
	ov_reset
	assert_gitlink_unchanged
	assert_submodule_clean
fi

# ---------------------------------------------------------------- release guards
if section 'release-guards'; then
	new_host relguards
	hc 'feat: a'
	assert_exit 'release refuses a non-production branch' 2 "$(hvrc release)"
	assert_contains 'and says why' 'not a production branch' "$(hv release)"
	assert_eq 'refusing created no tag' '' "$(git -C "$HOST" tag --list)"
	assert_exit '--any-branch overrides that' 0 "$(hvrc release --any-branch)"
	git -C "$HOST" tag -d v0.1.0 >/dev/null
	git -C "$HOST" reset -q --hard HEAD~1
	git -C "$HOST" checkout -q -b release/production
	git -C "$HOST" checkout -q --detach HEAD
	assert_exit 'release refuses a detached HEAD' 2 "$(hvrc release)"
	assert_contains 'and says why' 'detached' "$(hv release)"
	assert_eq 'refusing created no commit on the detached HEAD' '' "$(git -C "$HOST" tag --list)"
	git -C "$HOST" checkout -q release/production
	echo dirty >"$HOST/staged.txt"
	git -C "$HOST" add staged.txt
	assert_exit 'release refuses a dirty index' 2 "$(hvrc release)"
	assert_contains 'and says why' 'staged changes' "$(hv release)"
	git -C "$HOST" reset -q
	rm -f "$HOST/staged.txt"
	assert_exit 'release rejects an unknown flag' 2 "$(hvrc release --nope)"
	assert_exit 'release works once the guards are satisfied' 0 "$(hvrc release)"
	# a tag that exists but points somewhere else must not be silently retagged
	git -C "$HOST" checkout -q -b elsewhere main
	hc 'feat: parallel'
	git -C "$HOST" tag v0.2.0 HEAD
	git -C "$HOST" checkout -q release/production
	hc 'feat: mine'
	assert_exit 'release refuses to reuse a tag from another line of history' 2 "$(hvrc release)"
	assert_contains 'and says where the tag is' 'not in HEAD' "$(hv release)"
fi

# ---------------------------------------------------------------- release --push
if section 'release-push'; then
	new_host relpush
	BARE="$WORK/relpush-origin.git"
	git init -q --bare "$BARE"
	git -C "$HOST" remote add origin "$BARE"
	hc 'feat: a'
	git -C "$HOST" checkout -q -b release/production
	git -C "$HOST" push -q -u origin release/production
	assert_exit 'release --push succeeds' 0 "$(hvrc release --push)"
	assert_eq 'the tag reached the remote' 'v0.1.0' "$(git -C "$BARE" tag --list)"
	assert_eq 'the branch reached the remote' "$(hrev)" \
		"$(git -C "$BARE" rev-parse refs/heads/release/production)"
fi

# ---------------------------------------------------------------- install safety
if section 'install-safety'; then
	new_host installsafety
	printf '#!/bin/sh\n# somebody else was here\nexit 0\n' >"$HOST/.git/hooks/commit-msg"
	chmod +x "$HOST/.git/hooks/commit-msg"
	OUT="$(hv install)"
	assert_contains 'a foreign hook is backed up, not destroyed' 'backed up' "$OUT"
	assert_contains 'the backup keeps the original' 'somebody else was here' \
		"$(cat "$HOST/.git/hooks/commit-msg.pre-versioner")"
	assert_contains 'our hook is in place' 'Managed by versioner' "$(cat "$HOST/.git/hooks/commit-msg")"
	printf '#!/bin/sh\n# a second stranger\nexit 0\n' >"$HOST/.git/hooks/commit-msg"
	assert_exit 'a second foreign hook needs --force' 2 "$(hvrc install)"
	assert_exit '--force accepts it' 0 "$(hvrc install --force)"
	assert_exit 'install rejects unknown options' 2 "$(hvrc install --nope)"
fi

# ---------------------------------------------------------------- init
if section 'init'; then
	new_host initwire
	rm -f "$HOST/.git/hooks/commit-msg"
	OUT="$(hv init)"
	assert_true 'init installs the hook' test -x "$HOST/.git/hooks/commit-msg"
	assert_true 'init writes the PR gate workflow' test -f "$HOST/.gitea/workflows/versioner-pr-gate.yml"
	assert_true 'init writes the release workflow' test -f "$HOST/.gitea/workflows/versioner-auto-release.yml"
	assert_true 'init writes a policy skeleton' test -f "$HOST/external-overrides/00-policy.conf.example"
	assert_contains 'the workflow invokes the submodule script' './versioner/ci/pr-gate.sh' \
		"$(cat "$HOST/.gitea/workflows/versioner-pr-gate.yml")"
	assert_contains 'init prints a snippet for the parent AGENTS.md' 'AGENTS.md' "$OUT"
	assert_contains 'init is idempotent on a second run' 'skip' "$(hv init)"
	echo 'edited' >>"$HOST/.gitea/workflows/versioner-pr-gate.yml"
	hv init >/dev/null
	assert_contains 'init does not clobber without --force' 'edited' \
		"$(cat "$HOST/.gitea/workflows/versioner-pr-gate.yml")"
	hv init --force >/dev/null
	assert_not_contains 'init --force refreshes the file' 'edited' \
		"$(cat "$HOST/.gitea/workflows/versioner-pr-gate.yml")"
	assert_exit 'the policy skeleton is valid config' 0 \
		"$( (cd "$HOST" && cp external-overrides/00-policy.conf.example external-overrides/00-policy.conf \
			&& ./versioner/bin/versioner config >/dev/null 2>&1); echo $? )"
	rm -f "$HOST/external-overrides/00-policy.conf"
	assert_exit 'init rejects unknown options' 2 "$(hvrc init --nope)"
	assert_gitlink_unchanged
	assert_submodule_clean
fi

# ---------------------------------------------------------------- CI scripts
if section 'ci-scripts'; then
	new_host ci
	BARE="$WORK/ci-origin.git"
	git init -q --bare "$BARE"
	git -C "$HOST" remote add origin "$BARE"
	hc 'feat: a'
	git -C "$HOST" push -q -u origin main
	git -C "$HOST" checkout -q -b feature
	hc 'fix: good one'
	RC="$( (cd "$HOST" && GITEA_BASE_REF=main ./versioner/ci/pr-gate.sh >"$WORK/prgate.out" 2>&1); echo $? )"
	assert_exit 'pr-gate passes a clean PR' 0 "$RC"
	assert_contains 'pr-gate reports the range it linted' 'origin/main..HEAD' "$(cat "$WORK/prgate.out")"
	hc_nv 'garbage commit'
	RC="$( (cd "$HOST" && GITEA_BASE_REF=main ./versioner/ci/pr-gate.sh >/dev/null 2>&1); echo $? )"
	assert_exit 'pr-gate fails a PR with a bad commit' 1 "$RC"
	git -C "$HOST" reset -q --hard HEAD~1
	RC="$( (cd "$HOST" && VERSIONER_BASE_BRANCH=main ./versioner/ci/pr-gate.sh >/dev/null 2>&1); echo $? )"
	assert_exit 'pr-gate accepts VERSIONER_BASE_BRANCH' 0 "$RC"
	RC="$( (cd "$HOST" && GITEA_BASE_REF=nosuchbranch ./versioner/ci/pr-gate.sh >/dev/null 2>&1); echo $? )"
	assert_exit 'pr-gate reports an unfetchable base' 2 "$RC"

	# release.sh must survive the detached checkout CI hands it
	git -C "$HOST" checkout -q -b release/production main
	git -C "$HOST" push -q -u origin release/production
	git -C "$HOST" checkout -q --detach HEAD
	RC="$( (cd "$HOST" && GITEA_REF_NAME=release/production ./versioner/ci/release.sh >"$WORK/rel.out" 2>&1); echo $? )"
	assert_exit 'release.sh releases from a detached CI checkout' 0 "$RC"
	assert_contains 'release.sh re-attaches the branch' 're-attaching' "$(cat "$WORK/rel.out")"
	assert_eq 'release.sh pushed the tag' 'v0.1.0' "$(git -C "$BARE" tag --list)"
	assert_eq 'release.sh pushed the branch' "$(git -C "$HOST" rev-parse HEAD)" \
		"$(git -C "$BARE" rev-parse refs/heads/release/production)"
	RC="$( (cd "$HOST" && GITEA_REF_NAME=release/production ./versioner/ci/release.sh >/dev/null 2>&1); echo $? )"
	assert_exit 'release.sh is idempotent' 0 "$RC"
fi

# ---------------------------------------------------------------- fresh clone
if section 'fresh-clone'; then
	new_host freshsrc
	hc 'feat: a'
	hc 'perf: p'
	ov_write '10-policy.conf' 'bump.perf=patch'
	ov_commit
	CLONE="$WORK/fresh-clone"
	git clone -q "$HOST" "$CLONE"
	git -C "$CLONE" config user.email 'test@test'
	git -C "$CLONE" config user.name 'test'
	git -C "$CLONE" submodule update --init -q
	assert_true 'the submodule is checked out in the clone' test -x "$CLONE/versioner/bin/versioner"
	assert_eq 'the parent overrides came with the clone' '0.1.1' \
		"$( (cd "$CLONE" && ./versioner/bin/versioner version HEAD --strip-suffix 2>&1) )"
	assert_exit 'the hook installs in the clone' 0 \
		"$( (cd "$CLONE" && ./versioner/bin/versioner install >/dev/null 2>&1); echo $? )"
	if git -C "$CLONE" commit --allow-empty -q -m 'nope' 2>/dev/null; then
		fail 'the clone hook rejects a bad message' 'commit succeeded'
	else
		ok 'the clone hook rejects a bad message'
	fi
	echo x >>"$CLONE/app.txt"
	git -C "$CLONE" add -A
	if git -C "$CLONE" commit -q -m 'docs: in the clone' 2>/dev/null; then
		ok 'the clone hook accepts a good message'
	else
		fail 'the clone hook accepts a good message'
	fi
	# the hook resolves its own path, so a moved clone keeps working
	MOVED="$WORK/fresh-clone-moved"
	mv "$CLONE" "$MOVED"
	echo y >>"$MOVED/app.txt"
	git -C "$MOVED" add -A
	if git -C "$MOVED" commit -q -m 'docs: after moving the clone' 2>/dev/null; then
		ok 'the hook survives the repo being moved'
	else
		fail 'the hook survives the repo being moved'
	fi
	HOST="$WORK/freshsrc"
	assert_gitlink_unchanged
fi

# ---------------------------------------------------------------- CLI contract
if section 'cli-contract'; then
	new_host cli
	hc 'feat: a'
	assert_exit 'help exits 0' 0 "$(hvrc help)"
	assert_exit '--help exits 0' 0 "$(hvrc --help)"
	assert_exit 'an unknown command exits 2' 2 "$(hvrc nosuchcommand)"
	assert_exit 'an unknown version flag exits 2' 2 "$(hvrc version --bogus)"
	assert_exit 'an unknown config flag exits 2' 2 "$(hvrc config --bogus)"
	assert_exit 'an unknown check-tag flag exits 2' 2 "$(hvrc check-tag v1 --bogus)"
	assert_contains 'help lists every command' 'lint-range' "$(hv help)"
	assert_contains 'config reports the effective policy' 'production_branches' "$(hv config)"
	assert_contains 'config reports where overrides come from' 'external-overrides' "$(hv config)"
	# a broken policy must fail loudly rather than silently computing a wrong version
	ov_write '10-bad.conf' 'bump.feat=Minor'
	assert_exit 'a broken policy fails version' 2 "$(hvrc version)"
	assert_exit 'a broken policy fails the changelog' 2 "$(hvrc changelog -o /dev/null)"
	assert_contains 'and names the offending key' 'bump.feat' "$(hv version)"
	ov_reset
	ov_write '10-warn.conf' 'nonsense_key=1'
	assert_exit 'an unknown key only warns' 0 "$(hvrc version)"
	ov_reset
fi

summary 'e2e'
