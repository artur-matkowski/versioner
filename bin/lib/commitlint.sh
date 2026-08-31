# shellcheck shell=bash
# versioner commit message validation (strict Conventional Commits v1.0.0 subset)
#
# Header grammar:  type(scope)!: subject
#   type    lowercase, must be in $TYPES
#   scope   [A-Za-z0-9._-]+, optional
#   bang    "!" before the colon, optional breaking marker
#   subject non-empty, <= $SUBJECT_MAX chars, no trailing period
# Breaking can also be declared via a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer.
#
# Subjects matching $ignore_re are accepted unvalidated everywhere — the hook,
# lint-range, the fold and the changelog all consult the same list, so a merge
# or a revert is never rejected by one and ignored by another.

VERSIONER_HDR_RE='^([a-z]+)(\(([A-Za-z0-9._-]+)\))?(!)?: (.+)$'

# Validate a single header line. Prints one line per problem; returns 1 on failure.
lint_header() {
	local header="$1" problems=0 type subject
	if [[ ! "$header" =~ $VERSIONER_HDR_RE ]]; then
		printf 'invalid header (expected "type(scope)!: subject"): %s\n' "$header"
		return 1
	fi
	type="${BASH_REMATCH[1]}"
	subject="${BASH_REMATCH[5]}"
	if ! type_is_whitelisted "$type"; then
		printf 'unknown type "%s" (allowed: %s)\n' "$type" "$TYPES"
		problems=1
	fi
	if [ "${#subject}" -gt "$SUBJECT_MAX" ]; then
		printf 'subject exceeds %s chars (%s)\n' "$SUBJECT_MAX" "${#subject}"
		problems=1
	fi
	if [[ "$subject" == *. ]]; then
		printf 'subject must not end with a period\n'
		problems=1
	fi
	return "$problems"
}

# Validate the message file handed to us by the commit-msg hook.
commitlint_msg_file() {
	local file="$1" header
	if [ ! -s "$file" ]; then
		printf 'versioner: empty commit message\n' >&2
		return 1
	fi
	header="$(head -n1 "$file")"
	header="${header%$'\r'}"
	case "$header" in
	\#* | '')
		printf 'versioner: empty commit message\n' >&2
		return 1
		;;
	esac
	# merges, reverts and release commits are policy-ignored, not policy-violating
	if config_is_ignored "$header"; then
		return 0
	fi
	lint_header "$header"
}

# Validate every non-ignored commit in merge-base($base,$head)..$head.
commitlint_range() {
	local base="$1" head="${2:-HEAD}" errors=0 c subject problems mb
	git rev-parse -q --verify "${base}^{commit}" >/dev/null || {
		printf 'versioner: unknown base commit: %s\n' "$base" >&2
		return 2
	}
	git rev-parse -q --verify "${head}^{commit}" >/dev/null || {
		printf 'versioner: unknown head commit: %s\n' "$head" >&2
		return 2
	}
	mb="$(git merge-base "$base" "$head")" || {
		printf 'versioner: no common ancestor between %s and %s\n' "$base" "$head" >&2
		return 2
	}
	while IFS=$'\x01' read -r c subject; do
		[ -n "$c" ] || continue
		if config_is_ignored "$subject"; then
			continue
		fi
		if ! problems="$(lint_header "$subject")"; then
			errors=$((errors + 1))
			printf '%s\n' "$problems" | sed "s/^/versioner: ${c:0:$HASH_LEN}: /"
		fi
	done < <(git log --reverse --format="%H%x01%s" "${mb}..${head}")
	if [ "$errors" -ne 0 ]; then
		printf 'versioner: %s commit(s) failed validation in %s..%s\n' \
			"$errors" "${mb:0:$HASH_LEN}" "$(git rev-parse --short="$HASH_LEN" "$head")" >&2
		return 1
	fi
	printf 'versioner: OK: all commits in %s..%s pass\n' \
		"${mb:0:$HASH_LEN}" "$(git rev-parse --short="$HASH_LEN" "$head")"
	return 0
}
