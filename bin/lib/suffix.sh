# shellcheck shell=bash
# versioner branch suffix handling
#
# The bare X.Y.Z is a pure function of the commit. The suffix is *checkout
# context*: off-production commits get a strippable semver prerelease so dev
# builds are traceable and sort below the release:
#   X.Y.Z-<sanitized-branch>.<hash>
#
# Branch resolution order (first hit wins) — CI checks out a detached HEAD, so
# guessing from the checkout alone is not enough:
#   1. $VERSIONER_BRANCH (or `--branch <name>`)
#   2. CI-provided ref names: GITEA_REF_NAME, GITHUB_REF_NAME, CI_COMMIT_BRANCH
#   3. the checked-out branch (git symbolic-ref)
#   4. a branch that contains the commit (git name-rev)
#   5. the literal "detached"
#
# Sanitization: strip $STRIP_PREFIX, then map every non-alphanumeric character
# to '-' (semver identifiers allow [0-9A-Za-z-] only), collapse runs, trim edges.

sanitize_branch() {
	local b="$1"
	if [ -n "$STRIP_PREFIX" ]; then
		case "$b" in
		"$STRIP_PREFIX"*) b="${b#"$STRIP_PREFIX"}" ;;
		esac
	fi
	b="$(printf '%s' "$b" | tr -c '[:alnum:]' '-' | sed -E 's/-{2,}/-/g; s/^-//; s/-$//')"
	[ -n "$b" ] || b="detached"
	printf '%s' "$b"
}

resolve_branch() {
	local commit="${1:-HEAD}" b
	if [ -n "${VERSIONER_BRANCH:-}" ]; then
		printf '%s' "$VERSIONER_BRANCH"
		return 0
	fi
	for b in "${GITEA_REF_NAME:-}" "${GITHUB_REF_NAME:-}" "${CI_COMMIT_BRANCH:-}"; do
		if [ -n "$b" ]; then
			printf '%s' "$b"
			return 0
		fi
	done
	if b="$(git symbolic-ref --short -q HEAD 2>/dev/null)" && [ -n "$b" ]; then
		printf '%s' "$b"
		return 0
	fi
	b="$(git name-rev --name-only --no-undefined --refs='refs/heads/*' "$commit" 2>/dev/null || true)"
	b="${b%%[~^]*}"
	if [ -n "$b" ]; then
		printf '%s' "$b"
		return 0
	fi
	printf 'detached'
}

is_production_branch() {
	local b="$1" p
	for p in $PRODUCTION_BRANCHES; do
		[ "$b" = "$p" ] && return 0
	done
	return 1
}

# computed_version <commit> <strip:0|1>
# Prints the full version string (with suffix unless stripped or on a
# production branch).
computed_version() {
	local commit="$1" strip="${2:-0}" base branch h
	base="$(fold_version "$commit")" || return 1
	if [ "$strip" = 1 ]; then
		printf '%s\n' "$base"
		return 0
	fi
	branch="$(resolve_branch "$commit")"
	if is_production_branch "$branch"; then
		printf '%s\n' "$base"
		return 0
	fi
	h="$(git rev-parse --short="$HASH_LEN" "$commit")"
	printf '%s-%s.%s\n' "$base" "$(sanitize_branch "$branch")" "$h"
}
