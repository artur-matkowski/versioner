#!/usr/bin/env bash
# versioner test harness — single end-to-end workflow:
#   1. mirror this repo as a bare "remote"
#   2. init a dummy host repo, add versioner as a real submodule, install hook
#   3. build a scripted history in the host with the commit-msg hook active
#   4. exercise fold/suffix/lint/range/changelog/release through the submodule
#   5. prove every policy knob is configurable from the host's
#      external-overrides/ (tracked by the parent repo, never the submodule)
#   6. fresh-clone the host + submodule update --init (the CI checkout path)
#
# Usage: tests/run.sh        (KEEP=1 keeps tests/tmp/ for inspection)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/tmp"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$1"
	shift
	for l in "$@"; do printf '    %s\n' "$l"; done
}

assert_eq() { # desc want got
	if [ "$2" = "$3" ]; then ok; else fail "$1" "want: $2" "got:  $3"; fi
}
assert_exit() { # desc want got
	if [ "$2" = "$3" ]; then ok; else fail "$1" "want exit: $2" "got exit:  $3"; fi
}
assert_contains() { # desc needle haystack
	case "$3" in
	*"$2"*) ok ;;
	*) fail "$1" "missing: $2" "in: $3" ;;
	esac
}
assert_not_contains() { # desc needle haystack
	case "$3" in
	*"$2"*) fail "$1" "unexpected: $2" "in: $3" ;;
	*) ok ;;
	esac
}
assert_matches() { # desc regex got
	if [[ "$3" =~ $2 ]]; then ok; else fail "$1" "regex: $2" "got:  $3"; fi
}

# allow local-path submodule clones in this process only (git >= 2.39 blocks
# the file transport by default); user's global config stays untouched
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=protocol.file.allow
export GIT_CONFIG_VALUE_0=always

rm -rf "$WORK"
mkdir -p "$WORK"
if [ "${KEEP:-0}" = 1 ]; then
	trap 'printf "kept workdir: %s\n" "$WORK"' EXIT
else
	trap 'rm -rf "$WORK"' EXIT
fi

# ---------------------------------------------------------------- fixture
# bare mirror standing in for the real versioner remote
git clone --bare -q "$ROOT" "$WORK/remote.git"

# dummy host repo
HOST="$WORK/host"
git init -q -b main "$HOST"
git -C "$HOST" config user.email "test@test"
git -C "$HOST" config user.name "test"
echo '# host app' >"$HOST/README.md"
git -C "$HOST" add -A
git -C "$HOST" commit -q -m 'chore: init'

# versioner as a submodule of the host
git -C "$HOST" submodule add -q "$WORK/remote.git" versioner
git -C "$HOST" add -A
git -C "$HOST" commit -q -m 'chore: add versioner submodule'
GITLINK0="$(git -C "$HOST" ls-tree HEAD versioner)"

assert_eq 'wiring: .gitmodules path' 'versioner' "$(git -C "$HOST" config -f .gitmodules submodule.versioner.path)"
[ -x "$HOST/versioner/bin/versioner" ] && ok || fail 'wiring: submodule binary present'

# wire up the commit-msg hook, as in a real host
( cd "$HOST" && ./versioner/bin/versioner install ) >/dev/null 2>&1 && ok || fail 'wiring: install exits 0'
[ -x "$HOST/.git/hooks/commit-msg" ] && ok || fail 'wiring: hook installed and executable'
assert_contains 'wiring: hook points at submodule' "$HOST/versioner/bin/versioner" "$(cat "$HOST/.git/hooks/commit-msg")"

# ---------------------------------------------------------------- helpers
hc() { # msg
	echo "$RANDOM $RANDOM" >>"$HOST/app.txt"
	git -C "$HOST" add -A
	git -C "$HOST" commit -q -m "$1"
}
hc_nv() { # msg (--no-verify)
	echo "$RANDOM $RANDOM" >>"$HOST/app.txt"
	git -C "$HOST" add -A
	git -C "$HOST" commit -q --no-verify -m "$1"
}
hv() { (cd "$HOST" && ./versioner/bin/versioner "$@" 2>&1); }
hvrc() {
	(cd "$HOST" && ./versioner/bin/versioner "$@" >/dev/null 2>&1)
	echo $?
}
# overrides live in the host's external-overrides/, tracked by the parent repo
ov_write() { # file content
	mkdir -p "$HOST/external-overrides"
	printf '%s\n' "$2" >"$HOST/external-overrides/$1"
	git -C "$HOST" add -A
	if ! git -C "$HOST" diff --cached --quiet; then
		git -C "$HOST" commit -q -m 'chore: update external-overrides'
	fi
}
ov_reset() {
	rm -rf "$HOST/external-overrides"
	git -C "$HOST" add -A
	if ! git -C "$HOST" diff --cached --quiet; then
		git -C "$HOST" commit -q -m 'chore: reset external-overrides'
	fi
}
assert_submodule_clean() {
	local st
	st="$(git -C "$HOST/versioner" status --porcelain 2>/dev/null)"
	[ -z "$st" ] && ok || fail 'submodule untouched (status)' "$st"
}
assert_gitlink_unchanged() {
	assert_eq 'submodule untouched (gitlink)' "$GITLINK0" "$(git -C "$HOST" ls-tree HEAD versioner)"
}

# ---------------------------------------------------------------- history
# the hook is active: every commit below is validated
hc 'chore: app scaffold'
C1="$(git -C "$HOST" rev-parse HEAD)"
hc 'feat: a'
C2="$(git -C "$HOST" rev-parse HEAD)"
hc 'fix: b'
C3="$(git -C "$HOST" rev-parse HEAD)"
hc 'feat!: c'
C4="$(git -C "$HOST" rev-parse HEAD)"
hc 'docs: d'
C5="$(git -C "$HOST" rev-parse HEAD)"
hc 'feat(x): e'
C6="$(git -C "$HOST" rev-parse HEAD)"
git -C "$HOST" checkout -q -b side
hc 'feat: side'
git -C "$HOST" checkout -q main
# hook does not honor ignore_re (codified below): merge bypasses it
git -C "$HOST" merge -q --no-ff --no-verify side -m "Merge branch 'side'"
C7="$(git -C "$HOST" rev-parse HEAD)"

if git -C "$HOST" commit --allow-empty -q -m 'bad message' 2>"$WORK/hook-bad.err"; then
	fail 'hook: rejects bad message' 'commit succeeded'
else
	ok
fi
assert_contains 'hook: error output' 'invalid header' "$(cat "$WORK/hook-bad.err")"
git -C "$HOST" commit -q --allow-empty --no-verify -m 'bad message'
C8="$(git -C "$HOST" rev-parse HEAD)"

# ---------------------------------------------------------------- fold
assert_eq 'fold: chore init' '0.0.0' "$(hv version "$C1" --strip-suffix)"
assert_eq 'fold: feat -> 0.1.0' '0.1.0' "$(hv version "$C2" --strip-suffix)"
assert_eq 'fold: fix -> 0.1.1' '0.1.1' "$(hv version "$C3" --strip-suffix)"
assert_eq 'fold: feat! -> 1.0.0' '1.0.0' "$(hv version "$C4" --strip-suffix)"
assert_eq 'fold: docs is noop' '1.0.0' "$(hv version "$C5" --strip-suffix)"
assert_eq 'fold: scoped feat -> 1.1.0' '1.1.0' "$(hv version "$C6" --strip-suffix)"
assert_eq 'fold: merged side feat -> 1.2.0' '1.2.0' "$(hv version "$C7" --strip-suffix)"
assert_eq 'fold: bad message ignored' '1.2.0' "$(hv version "$C8" --strip-suffix)"

# ---------------------------------------------------------------- suffix
git -C "$HOST" checkout -q -b release/feature_test
H7="$(git -C "$HOST" rev-parse --short=7 HEAD)"
assert_eq 'suffix: feature_test sanitized' "1.2.0-feature-test.${H7}" "$(hv version)"
git -C "$HOST" checkout -q -b release/production
assert_eq 'suffix: production bare' '1.2.0' "$(hv version)"
git -C "$HOST" checkout -q "$C6"
assert_matches 'suffix: detached' '^1\.1\.0-HEAD\.[0-9a-f]{7}$' "$(hv version)"
git -C "$HOST" checkout -q main

# ---------------------------------------------------------------- lint-msg
M="$WORK/msg.txt"
printf 'feat: good\n\nbody line\n' >"$M"
assert_exit 'lint: valid message' 0 "$(hvrc lint-msg "$M")"
printf 'Feat: bad case\n' >"$M"
assert_exit 'lint: type must be lowercase' 1 "$(hvrc lint-msg "$M")"
printf 'feat:no space\n' >"$M"
assert_exit 'lint: space after colon required' 1 "$(hvrc lint-msg "$M")"
printf 'unknown: type\n' >"$M"
assert_exit 'lint: unknown type' 1 "$(hvrc lint-msg "$M")"
printf 'feat: trailing period.\n' >"$M"
assert_exit 'lint: no trailing period' 1 "$(hvrc lint-msg "$M")"
printf 'feat: %0100d\n' 0 >"$M"
assert_exit 'lint: subject too long' 1 "$(hvrc lint-msg "$M")"
printf 'feat(bad scope): x\n' >"$M"
assert_exit 'lint: bad scope char' 1 "$(hvrc lint-msg "$M")"
printf 'feat!: breaking bang ok\n' >"$M"
assert_exit 'lint: bang allowed' 0 "$(hvrc lint-msg "$M")"
printf 'fix: x\n\nBREAKING CHANGE: stuff\n' >"$M"
assert_exit 'lint: footer breaking ok' 0 "$(hvrc lint-msg "$M")"
: >"$M"
assert_exit 'lint: empty file' 1 "$(hvrc lint-msg "$M")"

# ---------------------------------------------------------------- lint-range
assert_exit 'range: includes bad commit' 1 "$(hvrc lint-range "$C1" "$C8")"
assert_exit 'range: clean range' 0 "$(hvrc lint-range "$C1" "$C7")"
assert_exit 'range: empty range' 0 "$(hvrc lint-range "$C2" "$C2")"
OUT="$(hv lint-range "$C1" "$C8")"
assert_contains 'range: names offending commit' 'invalid header' "$OUT"

# ---------------------------------------------------------------- hook
hc 'docs: after hook' && ok || fail 'hook: allows good message'

# ---------------------------------------------------------------- changelog
hv changelog HEAD -o "$WORK/cl.md" >/dev/null
VERS="$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$WORK/cl.md")"
assert_eq 'changelog: section order' "$(printf '1.2.0\n1.1.0\n1.0.0\n0.1.1\n0.1.0\n0.0.0')" "$VERS"
assert_contains 'changelog: breaking marker' '**BREAKING**' "$(cat "$WORK/cl.md")"
assert_contains 'changelog: scoped entry' 'feat(x): e' "$(cat "$WORK/cl.md")"
assert_contains 'changelog: merged commit listed' 'feat: side' "$(cat "$WORK/cl.md")"
assert_not_contains 'changelog: bad message omitted' 'bad message' "$(cat "$WORK/cl.md")"

# ---------------------------------------------------------------- overrides
# every key below is set via the host's external-overrides/ (default
# parent-relative location, no env var) and committed to the parent repo
ov_write '10-feat.conf' 'bump.feat=patch'
assert_eq 'override: default dir picked up, feat=patch' '1.0.1' "$(hv version "$C6" --strip-suffix)"
assert_gitlink_unchanged
assert_submodule_clean
ov_reset

ov_write '10-perf.conf' 'bump.perf=minor'
hc 'perf: p'
assert_eq 'override: perf=minor now bumps' '1.3.0' "$(hv version HEAD --strip-suffix)"
ov_reset

if git -C "$HOST" commit --allow-empty -q -m 'hotfix: h' 2>"$WORK/hook-hotfix.err"; then
	fail 'override: unknown type rejected by hook first' 'hook accepted hotfix'
else
	ok
fi
assert_contains 'override: hook names unknown type' 'unknown type' "$(cat "$WORK/hook-hotfix.err")"
ov_write '10-hotfix.conf' "$(printf 'types=feat fix chore docs refactor perf test style ci hotfix\nbump.hotfix=patch')"
hc 'hotfix: h' && ok || fail 'override: new type accepted by hook'
assert_eq 'override: new type bumps' '1.2.1' "$(hv version HEAD --strip-suffix)"
ov_reset

ov_write '10-ignore.conf' "$(printf 'ignore_re=^WIP\nignore_re=^feat\\(x\\)')"
# the hook does not honor ignore_re (codified current behavior)
if git -C "$HOST" commit --allow-empty -q -m 'WIP: wip work' 2>/dev/null; then
	fail 'override: hook still rejects ignored type (current behavior)' 'hook accepted WIP'
else
	ok
fi
hc_nv 'WIP: wip work'
assert_exit 'override: lint-range skips ignored commit' 0 "$(hvrc lint-range "$C8" HEAD)"
assert_eq 'override: ignored feat(x) changes fold' '1.1.0' "$(hv version "$C7" --strip-suffix)"
assert_eq 'override: WIP commit does not bump' '1.1.0' "$(hv version HEAD --strip-suffix)"
hv changelog HEAD -o "$WORK/cl-wip.md" >/dev/null
assert_not_contains 'override: ignored commit not in changelog' 'feat(x): e' "$(cat "$WORK/cl-wip.md")"
ov_reset

ov_write '10-prod.conf' 'production_branches=production'
git -C "$HOST" checkout -q -b production
assert_eq 'override: new production branch bare' '1.2.0' "$(hv version)"
git -C "$HOST" checkout -q main
assert_matches 'override: main still suffixed' '^1\.2\.0-main\.[0-9a-f]{7}$' "$(hv version)"
git -C "$HOST" branch -q -D production
ov_reset

git -C "$HOST" checkout -q -b release/staging
H6="$(git -C "$HOST" rev-parse --short=7 HEAD)"
assert_eq 'suffix default: strip_prefix release/' "1.2.0-staging.${H6}" "$(hv version)"
ov_write '10-strip.conf' 'strip_prefix='
assert_eq 'override: empty strip_prefix keeps full name' "1.2.0-release-staging.${H6}" "$(hv version)"
git -C "$HOST" checkout -q main
git -C "$HOST" branch -q -D release/staging
ov_reset

ov_write '10-hash.conf' 'hash_len=9'
assert_matches 'override: hash_len=9' '^1\.2\.0-main\.[0-9a-f]{9}$' "$(hv version)"
ov_reset

ov_write '10-tag.conf' 'tag_prefix=rel-'
LAST="$(git -C "$HOST" rev-parse HEAD)"
assert_exit 'release: runs with overridden tag prefix' 0 "$(hvrc release)"
[ -f "$HOST/CHANGELOG.md" ] && ok || fail 'release: creates CHANGELOG.md in host'
assert_eq 'release: commit message uses override' 'chore(release): rel-1.2.0' "$(git -C "$HOST" log -1 --format=%s)"
NEW="$(git -C "$HOST" rev-parse HEAD)"
[ "$NEW" != "$LAST" ] && ok || fail 'release: created release commit'
assert_exit 'release: check-tag passes' 0 "$(hvrc check-tag rel-1.2.0)"
git -C "$HOST" tag rel-9.9.9 "$C8"
assert_exit 'release: mismatched tag fails' 1 "$(hvrc check-tag rel-9.9.9)"
assert_exit 'release: idempotent' 0 "$(hvrc release)"
assert_eq 'release: idempotent no new commit' "$NEW" "$(git -C "$HOST" rev-parse HEAD)"
ov_reset

SUBJ="$(printf 'x%.0s' {1..80})"
printf 'feat: %s\n' "$SUBJ" >"$WORK/long.txt"
assert_exit 'lint: 80-char subject fails default (72)' 1 "$(hvrc lint-msg "$WORK/long.txt")"
ov_write '10-subj.conf' 'subject_max=100'
assert_exit 'override: subject_max=100 allows it' 0 "$(hvrc lint-msg "$WORK/long.txt")"
ov_reset

ov_write '10-a.conf' 'bump.fix=major'
ov_write '20-b.conf' 'bump.fix=noop'
assert_eq 'layering: later file wins (noop over major)' '0.1.0' "$(hv version "$C3" --strip-suffix)"
ov_write '20-b.conf' 'bump.fix=patch'
assert_eq 'layering: later file wins (patch over major)' '0.1.1' "$(hv version "$C3" --strip-suffix)"
ov_reset

ENV_OV="$WORK/env-overrides"
mkdir -p "$ENV_OV"
printf 'bump.feat=patch\n' >"$ENV_OV/00-env.conf"
assert_eq 'override: env dir works' '1.0.1' "$( (cd "$HOST" && VERSIONER_OVERRIDES_DIR="$ENV_OV" ./versioner/bin/versioner version "$C6" --strip-suffix 2>&1) )"
assert_eq 'override: default behavior without env' '1.1.0' "$(hv version "$C6" --strip-suffix)"
# env dir replaces the default dir entirely (it is not layered on top)
ov_write '10-feat.conf' 'bump.feat=patch'
printf 'bump.feat=major\n' >"$ENV_OV/00-env.conf"
assert_eq 'override: env dir replaces committed dir' '3.0.0' "$( (cd "$HOST" && VERSIONER_OVERRIDES_DIR="$ENV_OV" ./versioner/bin/versioner version "$C6" --strip-suffix 2>&1) )"
ov_reset

# final policy stays committed in the host (README-style usage)
ov_write '10-policy.conf' 'bump.perf=patch'
assert_eq 'final policy: perf commit bumps patch' '1.2.1' "$(hv version HEAD --strip-suffix)"
assert_gitlink_unchanged
assert_submodule_clean

# ---------------------------------------------------------------- fresh clone
CLONE="$WORK/host-clone"
git clone -q "$HOST" "$CLONE"
git -C "$CLONE" config user.email "test@test"
git -C "$CLONE" config user.name "test"
git -C "$CLONE" submodule update --init -q
[ -x "$CLONE/versioner/bin/versioner" ] && ok || fail 'clone: submodule checked out'
assert_eq 'clone: parent overrides carried over' '1.2.1' "$( (cd "$CLONE" && ./versioner/bin/versioner version HEAD --strip-suffix 2>&1) )"
( cd "$CLONE" && ./versioner/bin/versioner install ) >/dev/null 2>&1 && ok || fail 'clone: hook install'
if git -C "$CLONE" commit --allow-empty -q -m 'nope' 2>/dev/null; then
	fail 'clone: hook rejects bad message' 'commit succeeded'
else
	ok
fi
echo x >>"$CLONE/app.txt"
git -C "$CLONE" add -A
git -C "$CLONE" commit -q -m 'docs: in clone' && ok || fail 'clone: hook allows good message'

# ---------------------------------------------------------------- summary
assert_gitlink_unchanged
assert_submodule_clean
printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
