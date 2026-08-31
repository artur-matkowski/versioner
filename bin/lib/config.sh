# versioner config loader
#
# Policy resolution order (later wins):
#   1. seed defaults below
#   2. $VERSIONER_HOME/defaults/*.conf   (alphabetical, part of this submodule)
#   3. overrides dir, *.conf             (alphabetical, tracked by the PARENT repo,
#                                          buildroot-style; default location:
#                                          <parent of submodule>/external-overrides)
#
# File syntax: `key=value` lines, `#` comments, blank lines ignored.
# Special keys:
#   bump.<type>=<major|minor|patch|noop>  bump mapping (last occurrence wins)
#   ignore_re=<extended-regex>            append-only list of commit subjects to skip

VERSIONER_HOME="${VERSIONER_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# --- seed defaults (mirrored in defaults/*.conf) ---
TYPES="feat fix chore docs refactor perf test style ci"
BUMP_MAP="bump.breaking=major
bump.feat=minor
bump.fix=patch
bump.perf=noop
bump.refactor=noop
bump.chore=noop
bump.docs=noop
bump.test=noop
bump.style=noop
bump.ci=noop"
IGNORE_RES=""
PRODUCTION_BRANCHES="release/production"
STRIP_PREFIX="release/"
HASH_LEN=7
TAG_PREFIX="v"
SUBJECT_MAX=72

_versioner_read_conf_file() {
	local file="$1" line key val
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in
			'' | \#*) continue ;;
		esac
		case "$line" in
			*=*) ;;
			*)
				printf 'versioner: config: skipping malformed line in %s: %s\n' "$file" "$line" >&2
				continue
				;;
		esac
		key="${line%%=*}"
		val="${line#*=}"
		key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		case "$key" in
			'' | *[!A-Za-z0-9_.]*)
				printf 'versioner: config: skipping malformed key in %s: %s\n' "$file" "$line" >&2
				continue
				;;
		esac
		case "$key" in
			bump.*)
				BUMP_MAP="${BUMP_MAP}"$'\n'"${key}=${val}"
				;;
			ignore_re)
				IGNORE_RES="${IGNORE_RES}"$'\n'"${val}"
				;;
			*)
				printf -v "${key^^}" '%s' "$val"
				;;
		esac
	done <"$file"
}

config_load() {
	local f odir
	for f in "$VERSIONER_HOME"/defaults/*.conf; do
		[ -e "$f" ] || continue
		_versioner_read_conf_file "$f"
	done
	odir="${VERSIONER_OVERRIDES_DIR:-$(dirname "$VERSIONER_HOME")/external-overrides}"
	if [ -d "$odir" ]; then
		for f in "$odir"/*.conf; do
			[ -e "$f" ] || continue
			_versioner_read_conf_file "$f"
		done
	fi
}

# Print the bump level (major|minor|patch|noop) for a type; empty if unmapped.
bump_for_type() {
	local type="$1" line res=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
			"bump.${type}"=*) res="${line#*=}" ;;
		esac
	done <<<"$BUMP_MAP"
	printf '%s' "$res"
}

# True if $1 (a commit subject) matches any ignore regex.
config_is_ignored() {
	local s="$1" re
	while IFS= read -r re; do
		[ -n "$re" ] || continue
		if printf '%s' "$s" | grep -Eq "$re"; then
			return 0
		fi
	done <<<"$IGNORE_RES"
	return 1
}

type_is_whitelisted() {
	case " $TYPES " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}
