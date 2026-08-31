# versioner semver fold
#
# version(C) = fold over the full reachable history of commit C
# (topological order, oldest first), applying the bump mapped to each
# conventional commit with standard semver reset semantics:
#   major -> M+1.0.0 ; minor -> M.m+1.0 ; patch -> M.m.p+1
# Non-conventional and ignored commits never bump.
#
# This makes the version a pure function of the commit: the same commit
# always yields the same version on any branch. Tags are pins that can be
# verified with `versioner check-tag`, not inputs to the computation.

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
	elif [ -n "$msg" ] && printf '%s\n' "$msg" | grep -Eq '^BREAKING[- ]CHANGE:'; then
		BUMP_BREAKING=1
	fi
	if [ "$BUMP_BREAKING" = 1 ]; then
		BUMP_LEVEL="$(bump_for_type breaking)"
	else
		BUMP_LEVEL="$(bump_for_type "$BUMP_TYPE")"
	fi
	return 0
}

# Print the computed semver of a commit (default HEAD). No suffix.
fold_version() {
	local commit="${1:-HEAD}" major=0 minor=0 patch=0
	local out h msg header
	git rev-parse -q --verify "${commit}^{commit}" >/dev/null || {
		printf 'versioner: unknown commit: %s\n' "$commit" >&2
		return 1
	}
	out="$(git log --topo-order --reverse --format='%H%x01%B%x02' "$commit")" || return 1
	while [ -n "$out" ]; do
		h="${out%%$'\x01'*}"
		out="${out#*$'\x01'}"
		msg="${out%%$'\x02'*}"
		if [[ "$out" == *$'\x02'* ]]; then
			out="${out#*$'\x02'}"
		else
			out=""
		fi
		header="${msg%%$'\n'*}"
		if config_is_ignored "$header"; then
			continue
		fi
		if ! parse_bump "$header" "$msg"; then
			continue
		fi
		case "${BUMP_LEVEL:-}" in
		major)
			major=$((major + 1))
			minor=0
			patch=0
			;;
		minor)
			minor=$((minor + 1))
			patch=0
			;;
		patch) patch=$((patch + 1)) ;;
		esac
	done
	printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}
