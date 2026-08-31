#!/usr/bin/env bash
# versioner test runner.
#
#   tests/run.sh              run everything
#   tests/run.sh unit         run only the unit tests
#   tests/run.sh e2e          run only the end-to-end tests
#   VERBOSE=1 tests/run.sh    name every assertion as it passes
#   FILTER=release tests/run.sh   run only sections whose name contains "release"
#   KEEP=1 tests/run.sh       keep tests/tmp/ for inspection
#
# The suite tests the WORKING TREE: it snapshots the files on disk into a bare
# "remote" and wires that in as a real submodule. Cloning this repo directly
# would test the last commit instead, and a broken edit would still pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/tmp"
export ROOT WORK

WHICH="${1:-all}"
case "$WHICH" in
all | unit | e2e) ;;
*)
	printf 'usage: tests/run.sh [all|unit|e2e]\n' >&2
	exit 2
	;;
esac

# Allow local-path submodule clones in this process only (git >= 2.38 blocks the
# file transport by default); the user's global config stays untouched.
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

# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

RC=0

if [ "$WHICH" = all ] || [ "$WHICH" = unit ]; then
	printf '### unit\n'
	bash "$ROOT/tests/unit.sh" || RC=1
fi

if [ "$WHICH" = all ] || [ "$WHICH" = e2e ]; then
	printf '\n### e2e\n'
	stage_worktree "$WORK"
	# guard against ever regressing to testing HEAD instead of the working tree
	for f in bin/versioner bin/lib/fold.sh bin/lib/config.sh install.sh; do
		cmp -s "$ROOT/$f" "$WORK/src/$f" ||
			{ printf 'FAIL: the staged copy differs from the working tree: %s\n' "$f"; RC=1; }
	done
	bash "$ROOT/tests/e2e.sh" || RC=1
fi

if [ "$WHICH" = all ]; then
	printf '\n### shellcheck\n'
	if command -v shellcheck >/dev/null 2>&1; then
		# shellcheck disable=SC2046
		if shellcheck -e SC1090,SC1091 \
			bin/versioner bin/init.sh install.sh ci/*.sh hooks/commit-msg $(find bin/lib tests -name '*.sh'); then
			printf 'shellcheck: clean\n'
		else
			printf 'shellcheck: findings above\n'
			RC=1
		fi
	else
		printf 'shellcheck: not installed, skipped\n'
	fi
fi

if [ "$RC" -eq 0 ]; then
	printf '\nALL GREEN\n'
else
	printf '\nFAILURES\n'
fi
exit "$RC"
