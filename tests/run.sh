#!/usr/bin/env bash
# versioner test harness — builds throwaway fixture repos, asserts behavior.
# Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="${ROOT}/bin/versioner"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FIX=""

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

new_repo() {
	FIX="$TMP/repo"
	rm -rf "$FIX"
	mkdir -p "$FIX"
	git -C "$FIX" init -q -b main
	git -C "$FIX" config user.email "test@test"
	git -C "$FIX" config user.name "test"
}

c() { # msg
	{ echo "$RANDOM $RANDOM"; } >>"$FIX/f.txt"
	git -C "$FIX" add -A
	git -C "$FIX" commit -q -m "$1"
}

vv() { (cd "$FIX" && "$V" "$@" 2>&1); }
vvrc() {
	(cd "$FIX" && "$V" "$@" >/dev/null 2>&1)
	echo $?
}

# ---------------------------------------------------------------- fixture
new_repo
c 'chore: init'
C1="$(git -C "$FIX" rev-parse HEAD)"
c 'feat: a'
C2="$(git -C "$FIX" rev-parse HEAD)"
c 'fix: b'
C3="$(git -C "$FIX" rev-parse HEAD)"
c 'feat!: c'
C4="$(git -C "$FIX" rev-parse HEAD)"
c 'docs: d'
C5="$(git -C "$FIX" rev-parse HEAD)"
c 'feat(x): e'
C6="$(git -C "$FIX" rev-parse HEAD)"
git -C "$FIX" checkout -q -b side
c 'feat: side'
git -C "$FIX" checkout -q main
git -C "$FIX" merge -q --no-ff side -m "Merge branch 'side'"
C7="$(git -C "$FIX" rev-parse HEAD)"
c 'bad message'
C8="$(git -C "$FIX" rev-parse HEAD)"

# ---------------------------------------------------------------- fold
assert_eq 'fold: chore init' '0.0.0' "$(vv version "$C1" --strip-suffix)"
assert_eq 'fold: feat -> 0.1.0' '0.1.0' "$(vv version "$C2" --strip-suffix)"
assert_eq 'fold: fix -> 0.1.1' '0.1.1' "$(vv version "$C3" --strip-suffix)"
assert_eq 'fold: feat! -> 1.0.0' '1.0.0' "$(vv version "$C4" --strip-suffix)"
assert_eq 'fold: docs is noop' '1.0.0' "$(vv version "$C5" --strip-suffix)"
assert_eq 'fold: scoped feat -> 1.1.0' '1.1.0' "$(vv version "$C6" --strip-suffix)"
assert_eq 'fold: merged side feat -> 1.2.0' '1.2.0' "$(vv version "$C7" --strip-suffix)"
assert_eq 'fold: bad message ignored' '1.2.0' "$(vv version "$C8" --strip-suffix)"

# ---------------------------------------------------------------- suffix
git -C "$FIX" checkout -q -b release/feature_test
H7="$(git -C "$FIX" rev-parse --short=7 HEAD)"
assert_eq 'suffix: feature_test sanitized' "1.2.0-feature-test.${H7}" "$(vv version)"
git -C "$FIX" checkout -q -b release/production
assert_eq 'suffix: production bare' '1.2.0' "$(vv version)"
git -C "$FIX" checkout -q "$C6"
assert_matches 'suffix: detached' '^1\.1\.0-HEAD\.[0-9a-f]{7}$' "$(vv version)"
git -C "$FIX" checkout -q main

# ---------------------------------------------------------------- lint-msg
M="$TMP/msg.txt"
printf 'feat: good\n\nbody line\n' >"$M"
assert_exit 'lint: valid message' 0 "$(vvrc lint-msg "$M")"
printf 'Feat: bad case\n' >"$M"
assert_exit 'lint: type must be lowercase' 1 "$(vvrc lint-msg "$M")"
printf 'feat:no space\n' >"$M"
assert_exit 'lint: space after colon required' 1 "$(vvrc lint-msg "$M")"
printf 'unknown: type\n' >"$M"
assert_exit 'lint: unknown type' 1 "$(vvrc lint-msg "$M")"
printf 'feat: trailing period.\n' >"$M"
assert_exit 'lint: no trailing period' 1 "$(vvrc lint-msg "$M")"
printf 'feat: %0100d\n' 0 >"$M"
assert_exit 'lint: subject too long' 1 "$(vvrc lint-msg "$M")"
printf 'feat(bad scope): x\n' >"$M"
assert_exit 'lint: bad scope char' 1 "$(vvrc lint-msg "$M")"
printf 'feat!: breaking bang ok\n' >"$M"
assert_exit 'lint: bang allowed' 0 "$(vvrc lint-msg "$M")"
printf 'fix: x\n\nBREAKING CHANGE: stuff\n' >"$M"
assert_exit 'lint: footer breaking ok' 0 "$(vvrc lint-msg "$M")"
: >"$M"
assert_exit 'lint: empty file' 1 "$(vvrc lint-msg "$M")"

# ---------------------------------------------------------------- lint-range
assert_exit 'range: includes bad commit' 1 "$(vvrc lint-range "$C1" "$C8")"
assert_exit 'range: clean range' 0 "$(vvrc lint-range "$C1" "$C7")"
assert_exit 'range: empty range' 0 "$(vvrc lint-range "$C2" "$C2")"
OUT="$(vv lint-range "$C1" "$C8")"
assert_contains 'range: names offending commit' 'invalid header' "$OUT"

# ---------------------------------------------------------------- changelog
vv changelog HEAD -o "$TMP/cl.md" >/dev/null
VERS="$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$TMP/cl.md")"
assert_eq 'changelog: section order' "$(printf '1.2.0\n1.1.0\n1.0.0\n0.1.1\n0.1.0\n0.0.0')" "$VERS"
assert_contains 'changelog: breaking marker' '**BREAKING**' "$(cat "$TMP/cl.md")"
assert_contains 'changelog: scoped entry' 'feat(x): e' "$(cat "$TMP/cl.md")"
assert_contains 'changelog: merged commit listed' 'feat: side' "$(cat "$TMP/cl.md")"
assert_not_contains 'changelog: bad message omitted' 'bad message' "$(cat "$TMP/cl.md")"

# ---------------------------------------------------------------- release
git -C "$FIX" checkout -q release/production
LAST="$(git -C "$FIX" rev-parse HEAD)"
assert_exit 'release: runs' 0 "$(vvrc release)"
[ -f "$FIX/CHANGELOG.md" ] && ok || fail 'release: creates CHANGELOG.md'
assert_eq 'release: commit message' 'chore(release): v1.2.0' "$(git -C "$FIX" log -1 --format=%s)"
NEW="$(git -C "$FIX" rev-parse HEAD)"
[ "$NEW" != "$LAST" ] && ok || fail 'release: created release commit'
assert_exit 'release: tag exists' 0 "$(vvrc check-tag v1.2.0)"
git -C "$FIX" tag v9.9.9
assert_exit 'release: mismatched tag fails' 1 "$(vvrc check-tag v9.9.9)"
assert_exit 'release: idempotent' 0 "$(vvrc release)"
assert_eq 'release: idempotent no new commit' "$NEW" "$(git -C "$FIX" rev-parse HEAD)"

# ---------------------------------------------------------------- overrides
mkdir -p "$TMP/ext"
printf 'bump.feat=patch\n' >"$TMP/ext/override.conf"
GOT="$(cd "$FIX" && VERSIONER_OVERRIDES_DIR="$TMP/ext" "$V" version "$C6" --strip-suffix 2>&1)"
assert_eq 'override: feat=patch changes fold' '1.0.1' "$GOT"

# ---------------------------------------------------------------- hook
assert_exit 'hook: install' 0 "$(vvrc install)"
[ -x "$FIX/.git/hooks/commit-msg" ] && ok || fail 'hook: installed and executable'
git -C "$FIX" commit --allow-empty -q -m 'not conventional' 2>"$TMP/hook.err"
RC=$?
[ "$RC" -ne 0 ] && ok || fail 'hook: rejects bad message (exit 0)'
assert_contains 'hook: error output' 'invalid header' "$(cat "$TMP/hook.err")"
echo x >>"$FIX/f.txt"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m 'feat: after hook' && ok || fail 'hook: allows good message'

# ---------------------------------------------------------------- summary
printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
