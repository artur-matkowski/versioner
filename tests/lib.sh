# shellcheck shell=bash
# versioner test helpers.
#
# The important part is stage_worktree(): the suite must test the files on
# disk, not the last commit. Cloning $ROOT directly (as this harness used to)
# silently tests HEAD, so a broken working tree still reports all-green.

# ROOT and WORK are exported by tests/run.sh.
# shellcheck disable=SC2154,SC2153

PASS=0
FAIL=0
CURRENT=""
SEQ=0

section() { # <name> — returns 1 when FILTER excludes it
	CURRENT="$1"
	case "$1" in
	*${FILTER:-}*) ;;
	*) return 1 ;;
	esac
	[ "${VERBOSE:-0}" = 1 ] && printf '\n== %s\n' "$1"
	return 0
}

ok() {
	PASS=$((PASS + 1))
	if [ "${VERBOSE:-0}" = 1 ]; then printf '  ok    %s\n' "${1:-}"; fi
	return 0
}

fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: [%s] %s\n' "$CURRENT" "$1"
	shift
	for l in "$@"; do printf '      %s\n' "$l"; done
	return 0
}

assert_eq() { # desc want got
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi
}
assert_exit() { # desc want got
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want exit: $2" "got exit:  $3"; fi
}
assert_contains() { # desc needle haystack
	case "$3" in
	*"$2"*) ok "$1" ;;
	*) fail "$1" "missing: $2" "in: $3" ;;
	esac
}
assert_not_contains() { # desc needle haystack
	case "$3" in
	*"$2"*) fail "$1" "unexpected: $2" "in: $3" ;;
	*) ok "$1" ;;
	esac
}
assert_matches() { # desc regex got
	if [[ "$3" =~ $2 ]]; then ok "$1"; else fail "$1" "regex: $2" "got:  $3"; fi
}
assert_not_matches() { # desc regex got
	if [[ "$3" =~ $2 ]]; then fail "$1" "unexpected match: $2" "got:  $3"; else ok "$1"; fi
}
assert_true() { # desc <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc" "command failed: $*"; fi
}
assert_false() { # desc <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then fail "$desc" "command unexpectedly succeeded: $*"; else ok "$desc"; fi
}

summary() {
	printf '\n%s: passed %s, failed %s\n' "${1:-tests}" "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}

# --- fixture construction -------------------------------------------------

# Copy the WORKING TREE (not HEAD) into $1/src and mirror it to $1/remote.git,
# so the submodule the tests wire up is exactly the code on disk. Skips .git
# and tests/tmp; tests/tmp is inside $ROOT, so a plain `cp -a $ROOT` would
# recurse into its own destination.
stage_worktree() { # <workdir>
	local work="$1" src="$1/src" entry
	mkdir -p "$src/tests"
	for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
		[ -e "$entry" ] || continue
		case "$entry" in
		"$ROOT"/.git | "$ROOT"/tests) continue ;;
		esac
		cp -a "$entry" "$src/"
	done
	for entry in "$ROOT"/tests/*; do
		[ -e "$entry" ] || continue
		case "$entry" in
		"$ROOT"/tests/tmp) continue ;;
		esac
		cp -a "$entry" "$src/tests/"
	done
	git init -q -b main "$src"
	git -C "$src" config user.email 'versioner@test'
	git -C "$src" config user.name 'versioner-test'
	git -C "$src" add -A
	git -C "$src" commit -q -m 'chore: snapshot of the working tree under test'
	git clone --bare -q "$src" "$work/remote.git"
}

# Fresh host repo with versioner wired in as a real submodule. Each scenario
# gets its own, so scenarios cannot perturb each other's versions or hashes.
new_host() { # <name>
	HOST="$WORK/$1"
	git init -q -b main "$HOST"
	git -C "$HOST" config user.email 'test@test'
	git -C "$HOST" config user.name 'test'
	echo '# host app' >"$HOST/README.md"
	git -C "$HOST" add -A
	git -C "$HOST" commit -q -m 'chore: init'
	git -C "$HOST" submodule add -q "$WORK/remote.git" versioner
	git -C "$HOST" add -A
	git -C "$HOST" commit -q -m 'chore: add versioner submodule'
	GITLINK0="$(git -C "$HOST" ls-tree HEAD versioner)"
	(cd "$HOST" && ./versioner/bin/versioner install) >/dev/null
}

hc() { # host commit (hook active)
	SEQ=$((SEQ + 1))
	echo "line $SEQ" >>"$HOST/app.txt"
	git -C "$HOST" add -A
	git -C "$HOST" commit -q -m "$1"
}
hc_nv() { # host commit, bypassing the hook
	SEQ=$((SEQ + 1))
	echo "line $SEQ" >>"$HOST/app.txt"
	git -C "$HOST" add -A
	git -C "$HOST" commit -q --no-verify -m "$1"
}
hv() { (cd "$HOST" && ./versioner/bin/versioner "$@" 2>&1); }
hvrc() {
	(cd "$HOST" && ./versioner/bin/versioner "$@" >/dev/null 2>&1)
	echo $?
}
hrev() { git -C "$HOST" rev-parse "${1:-HEAD}"; }
hshort() { git -C "$HOST" rev-parse --short="${2:-7}" "${1:-HEAD}"; }

# Overrides live in the host's external-overrides/. They take effect from the
# filesystem; only the fresh-clone scenario needs them committed, so writing
# one does not create a commit that would shift every later version.
ov_write() { # file content
	mkdir -p "$HOST/external-overrides"
	printf '%s\n' "$2" >"$HOST/external-overrides/$1"
}
ov_reset() { rm -rf "$HOST/external-overrides"; }
ov_commit() {
	git -C "$HOST" add -A
	git -C "$HOST" diff --cached --quiet || git -C "$HOST" commit -q -m 'chore: update external-overrides'
}

assert_submodule_clean() {
	local st
	st="$(git -C "$HOST/versioner" status --porcelain 2>/dev/null)"
	if [ -z "$st" ]; then ok 'submodule worktree untouched'; else fail 'submodule worktree untouched' "$st"; fi
}
assert_gitlink_unchanged() {
	assert_eq 'submodule gitlink untouched' "$GITLINK0" "$(git -C "$HOST" ls-tree HEAD versioner)"
}
