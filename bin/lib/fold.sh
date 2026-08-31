# shellcheck shell=bash
# shellcheck disable=SC2034  # policy variables are read by the sibling libs
# versioner semver fold
#
# version(C) = fold over the full reachable history of commit C
# (topological order, oldest first), applying the bump mapped to each
# conventional commit with standard semver reset semantics:
#   major -> M+1.0.0 ; minor -> M.m+1.0 ; patch -> M.m.p+1
# Non-conventional and ignored commits never bump.
#
# The bare X.Y.Z is a pure function of the commit: the same commit always
# yields the same version on any branch and in any checkout. Tags are pins
# that can be verified with `versioner check-tag`, not inputs.

# A BREAKING CHANGE footer only counts at the start of a line.
VERSIONER_BREAKING_RE=$'\nBREAKING[- ]CHANGE:'

# Parse a commit header (+ full message for footer detection).
# Sets: BUMP_TYPE BUMP_SCOPE BUMP_SUBJECT BUMP_BREAKING BUMP_LEVEL
# Returns 1 if the commit does not contribute to the version.
parse_bump() {
	local header="$1" msg="${2-}"
	BUMP_TYPE=""
	BUMP_SCOPE=""
	BUMP_SUBJECT=""
	BUMP_BREAKING=0
	BUMP_LEVEL=""
	if [[ ! "$header" =~ $VERSIONER_HDR_RE ]]; then
		return 1
	fi
	BUMP_TYPE="${BASH_REMATCH[1]}"
	BUMP_SCOPE="${BASH_REMATCH[3]:-}"
	BUMP_SUBJECT="${BASH_REMATCH[5]:-}"
	if ! type_is_whitelisted "$BUMP_TYPE"; then
		return 1
	fi
	if [ -n "${BASH_REMATCH[4]:-}" ]; then
		BUMP_BREAKING=1
	elif [ -n "$msg" ] && [[ $'\n'"$msg" =~ $VERSIONER_BREAKING_RE ]]; then
		BUMP_BREAKING=1
	fi
	# read the map directly: a $(bump_for_type) subshell here would fork once
	# per commit and dominate the runtime on a large history
	if [ "$BUMP_BREAKING" = 1 ]; then
		BUMP_LEVEL="${BUMP_LEVEL_OF[breaking]:-}"
	else
		BUMP_LEVEL="${BUMP_LEVEL_OF[$BUMP_TYPE]:-}"
	fi
	return 0
}

# Apply one commit to the running _FOLD_* counters.
_fold_apply() {
	local msg="$3" header
	header="${msg%%$'\n'*}"
	config_is_ignored "$header" && return 0
	parse_bump "$header" "$msg" || return 0
	case "${BUMP_LEVEL:-}" in
	major)
		_FOLD_MAJOR=$((_FOLD_MAJOR + 1))
		_FOLD_MINOR=0
		_FOLD_PATCH=0
		;;
	minor)
		_FOLD_MINOR=$((_FOLD_MINOR + 1))
		_FOLD_PATCH=0
		;;
	patch) _FOLD_PATCH=$((_FOLD_PATCH + 1)) ;;
	esac
	return 0
}

# Print the computed semver of a commit (default HEAD). No suffix.
fold_version() {
	local commit="${1:-HEAD}"
	_FOLD_MAJOR=0
	_FOLD_MINOR=0
	_FOLD_PATCH=0
	history_each "$commit" _fold_apply || return 1
	printf '%d.%d.%d\n' "$_FOLD_MAJOR" "$_FOLD_MINOR" "$_FOLD_PATCH"
}
