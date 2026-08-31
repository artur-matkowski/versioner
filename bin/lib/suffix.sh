# versioner branch suffix handling
#
# Off-production commits get a strippable semver prerelease suffix:
#   X.Y.Z-<sanitized-branch>.<hash7>
# Commits viewed from a production branch print the bare X.Y.Z.
# Sanitization: strip $STRIP_PREFIX, then map every non-alphanumeric
# character to '-' (semver identifiers allow [0-9A-Za-z-] only),
# collapse runs, trim edges.

sanitize_branch() {
	local b="$1"
	case "$b" in
	"$STRIP_PREFIX"*) b="${b#"$STRIP_PREFIX"}" ;;
	esac
	b="$(printf '%s' "$b" | tr -c '[:alnum:]' '-' | sed -E 's/-{2,}/-/g; s/^-//; s/-$//')"
	[ -n "$b" ] || b="head"
	printf '%s' "$b"
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
	branch="$(git rev-parse --abbrev-ref HEAD)"
	if is_production_branch "$branch"; then
		printf '%s\n' "$base"
		return 0
	fi
	h="$(git rev-parse --short="$HASH_LEN" "$commit")"
	printf '%s-%s.%s\n' "$base" "$(sanitize_branch "$branch")" "$h"
}
