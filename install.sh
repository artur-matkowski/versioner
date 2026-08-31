#!/usr/bin/env bash
# Install the versioner commit-msg hook into the surrounding git repo.
#
# An existing hook that versioner did not write is backed up to
# commit-msg.pre-versioner rather than destroyed; --force overwrites a backup
# that is already there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER='Managed by versioner install'
FORCE=0

for a in "$@"; do
	case "$a" in
	--force) FORCE=1 ;;
	*)
		printf 'versioner: install: unknown option: %s\n' "$a" >&2
		exit 2
		;;
	esac
done

git rev-parse --git-dir >/dev/null 2>&1 || {
	printf 'versioner: not inside a git repository\n' >&2
	exit 2
}

TOPLEVEL="$(git rev-parse --show-toplevel)"
# Prefer a repo-relative path so the hook survives the repo being moved or
# cloned elsewhere; fall back to absolute when versioner lives outside the repo.
case "$ROOT/" in
"$TOPLEVEL"/*) BIN="${ROOT#"$TOPLEVEL"/}/bin/versioner" ;;
*)
	BIN="${ROOT}/bin/versioner"
	printf 'versioner: note: %s is outside %s; the hook will use an absolute path\n' "$ROOT" "$TOPLEVEL" >&2
	;;
esac

# Resolve the hooks directory absolutely: `git rev-parse --git-path` answers
# relative to the current directory, so installing from a subdirectory would
# otherwise look like a core.hooksPath override.
HOOKS_DIR="$(git config --get core.hooksPath || true)"
if [ -n "$HOOKS_DIR" ]; then
	case "$HOOKS_DIR" in
	/*) ;;
	*) HOOKS_DIR="${TOPLEVEL}/${HOOKS_DIR}" ;;
	esac
	printf 'versioner: note: core.hooksPath sends hooks to %s (shared with other repos?)\n' "$HOOKS_DIR" >&2
else
	HOOKS_DIR="$(git rev-parse --absolute-git-dir)/hooks"
fi
mkdir -p "$HOOKS_DIR"
TARGET="${HOOKS_DIR}/commit-msg"

if [ -e "$TARGET" ] && ! grep -q "$MARKER" "$TARGET" 2>/dev/null; then
	BACKUP="${TARGET}.pre-versioner"
	if [ -e "$BACKUP" ] && [ "$FORCE" != 1 ]; then
		printf 'versioner: %s exists and %s is already taken; rerun with --force\n' "$TARGET" "$BACKUP" >&2
		exit 2
	fi
	mv "$TARGET" "$BACKUP"
	printf 'versioner: backed up the existing commit-msg hook -> %s\n' "$BACKUP"
fi

TPL="$(cat "${ROOT}/hooks/commit-msg")"
printf '%s\n' "${TPL//__VERSIONER_BIN__/$BIN}" >"$TARGET"
chmod +x "$TARGET"
printf 'versioner: installed commit-msg hook -> %s (runs %s)\n' "$TARGET" "$BIN"
