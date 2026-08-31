#!/usr/bin/env bash
# versioner auto-release — changelog + release commit + annotated tag + push.
#
# Invoked by the parent repo's workflow; all logic lives here in the submodule.
# CI usually checks out a detached HEAD, so re-attach to the branch that was
# pushed before releasing (versioner refuses to release from a detached HEAD).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONER="${HERE}/../bin/versioner"

git config user.name >/dev/null 2>&1 || git config user.name 'versioner[bot]'
git config user.email >/dev/null 2>&1 || git config user.email 'versioner@bot'

if ! git symbolic-ref -q HEAD >/dev/null; then
	branch="${GITEA_REF_NAME:-${GITHUB_REF_NAME:-}}"
	branch="${branch#refs/heads/}"
	if [ -z "$branch" ]; then
		printf 'versioner: release: HEAD is detached and no CI ref name is set\n' >&2
		exit 2
	fi
	printf 'versioner: release: re-attaching detached HEAD to %s\n' "$branch"
	git checkout -q -B "$branch" HEAD
fi

exec "$VERSIONER" release --push "$@"
