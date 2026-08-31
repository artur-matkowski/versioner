#!/usr/bin/env bash
# versioner PR gate — lint only the commits a PR adds.
#
# Invoked by the parent repo's workflow; all logic lives here in the submodule
# so `git submodule update --remote` ships fixes without touching the parent.
#
# Base branch resolution (first hit wins):
#   1. the CI's PR base ref  (GITEA_BASE_REF / GITHUB_BASE_REF)
#   2. $VERSIONER_BASE_BRANCH
#   3. the remote's default branch (origin/HEAD)
# Runs anywhere, not just in CI: `ci/pr-gate.sh` in a local clone works too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONER="${HERE}/../bin/versioner"

base="${GITEA_BASE_REF:-${GITHUB_BASE_REF:-${VERSIONER_BASE_BRANCH:-}}}"
if [ -z "$base" ]; then
	base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	base="${base#origin/}"
fi
if [ -z "$base" ]; then
	printf 'versioner: pr-gate: cannot determine the base branch; set VERSIONER_BASE_BRANCH\n' >&2
	exit 2
fi
base="${base#refs/heads/}"

if ! git rev-parse -q --verify "refs/remotes/origin/${base}" >/dev/null; then
	printf 'versioner: pr-gate: fetching origin/%s\n' "$base"
	git fetch --quiet origin "+refs/heads/${base}:refs/remotes/origin/${base}" || {
		printf 'versioner: pr-gate: cannot fetch base branch %s from origin\n' "$base" >&2
		exit 2
	}
fi

printf 'versioner: pr-gate: linting origin/%s..HEAD\n' "$base"
exec "$VERSIONER" lint-range "origin/${base}" HEAD
