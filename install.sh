#!/usr/bin/env bash
# Install the versioner commit-msg hook into the surrounding git repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git rev-parse --git-dir >/dev/null 2>&1 || {
	printf 'versioner: not inside a git repository\n' >&2
	exit 1
}

HOOKS_DIR="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS_DIR"
sed "s|__VERSIONER__|${ROOT}/bin/versioner|" "${ROOT}/hooks/commit-msg" >"${HOOKS_DIR}/commit-msg"
chmod +x "${HOOKS_DIR}/commit-msg"
printf 'versioner: installed commit-msg hook -> %s\n' "$HOOKS_DIR/commit-msg"
