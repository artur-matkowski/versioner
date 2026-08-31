# versioner commit message validation (strict Conventional Commits v1.0.0 subset)
#
# Header grammar:  type(scope)!: subject
#   type    lowercase, must be in $TYPES
#   scope   [A-Za-z0-9._-]+, optional
#   !       breaking marker, optional
#   subject non-empty, <= $SUBJECT_MAX chars, no trailing period
# Breaking can also be declared via a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer.

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
	header="$(head -n1 "$file" | sed 's/\r$//')"
	case "$header" in
	\#* | '')
		printf 'versioner: empty commit message\n' >&2
		return 1
		;;
	esac
	lint_header "$header"
}

# Validate every non-ignored commit in merge-base($base,$head)..$head.
commitlint_range() {
	local base="$1" head="${2:-HEAD}" errors=0 c subject short mb
	git rev-parse -q --verify "${base}^{commit}" >/dev/null || {
		printf 'versioner: unknown base commit: %s\n' "$base" >&2
		return 1
	}
	git rev-parse -q --verify "${head}^{commit}" >/dev/null || {
		printf 'versioner: unknown head commit: %s\n' "$head" >&2
		return 1
	}
	mb="$(git merge-base "$base" "$head")" || {
		printf 'versioner: no common ancestor between %s and %s\n' "$base" "$head" >&2
		return 1
	}
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		subject="$(git log -1 --format=%s "$c")"
		if config_is_ignored "$subject"; then
			continue
		fi
		short="$(git rev-parse --short=7 "$c")"
		if ! subject="$(lint_header "$subject")"; then
			errors=$((errors + 1))
			printf '%s\n' "$subject" | sed "s/^/versioner: ${short}: /"
		fi
	done < <(git rev-list --reverse "${mb}..${head}")
	if [ "$errors" -ne 0 ]; then
		printf 'versioner: %s commit(s) failed validation in %s..%s\n' "$errors" "${mb:0:7}" "$(git rev-parse --short=7 "$head")" >&2
		return 1
	fi
	printf 'versioner: OK: all commits in %s..%s pass\n' "${mb:0:7}" "$(git rev-parse --short=7 "$head")"
	return 0
}
