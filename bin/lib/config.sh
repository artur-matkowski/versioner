# shellcheck shell=bash
# shellcheck disable=SC2034  # policy variables are read by the sibling libs
# versioner config loader
#
# Policy resolution order (later wins):
#   1. $VERSIONER_HOME/defaults/*.conf   (alphabetical, shipped by this submodule —
#                                          the single source of truth for defaults)
#   2. overrides dir, *.conf             (alphabetical, tracked by the PARENT repo,
#                                          buildroot-style; default location:
#                                          <parent of submodule>/external-overrides,
#                                          or $VERSIONER_OVERRIDES_DIR, which REPLACES
#                                          the default dir rather than layering on it)
#
# File syntax: `key=value` lines, `#` comments, blank lines ignored.
# Only the keys listed in _VERSIONER_KEYS below are accepted; anything else warns
# and is skipped (a conf file can never assign an arbitrary shell variable).
# Special keys:
#   bump.<type>=<major|minor|patch|noop>  bump mapping (last occurrence wins)
#   ignore_re=<extended-regex>            append to the ignore list
#   ignore_re=                            (empty value) reset the ignore list

VERSIONER_HOME="${VERSIONER_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Every scalar policy key. bump.* and ignore_re are handled separately.
_VERSIONER_KEYS="types production_branches strip_prefix hash_len tag_prefix subject_max"

TYPES=""
PRODUCTION_BRANCHES=""
STRIP_PREFIX=""
HASH_LEN=""
TAG_PREFIX=""
SUBJECT_MAX=""
IGNORE_RES=""
IGNORE_RE_ALL=""
declare -gA BUMP_LEVEL_OF=()
declare -gA CONF_SRC=()

_conf_warn() { printf 'versioner: config: %s\n' "$1" >&2; }
_conf_die() {
	printf 'versioner: config: %s\n' "$1" >&2
	exit 2
}

_versioner_read_conf_file() {
	local file="$1" line key val lineno=0
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		line="${line%$'\r'}"
		case "$line" in
		'' | \#*) continue ;;
		esac
		case "$line" in
		*=*) ;;
		*)
			_conf_warn "${file}:${lineno}: not a key=value line, skipped: ${line}"
			continue
			;;
		esac
		key="${line%%=*}"
		val="${line#*=}"
		key="${key#"${key%%[![:space:]]*}"}"
		key="${key%"${key##*[![:space:]]}"}"
		val="${val#"${val%%[![:space:]]*}"}"
		val="${val%"${val##*[![:space:]]}"}"
		case "$key" in
		bump.*)
			BUMP_LEVEL_OF["${key#bump.}"]="$val"
			CONF_SRC["$key"]="$file"
			;;
		ignore_re)
			if [ -z "$val" ]; then
				IGNORE_RES=""
				CONF_SRC[ignore_re]="${file} (reset)"
			else
				IGNORE_RES="${IGNORE_RES}${IGNORE_RES:+$'\n'}${val}"
				CONF_SRC[ignore_re]="${CONF_SRC[ignore_re]:+${CONF_SRC[ignore_re]}, }${file}"
			fi
			;;
		*)
			case " $_VERSIONER_KEYS " in
			*" $key "*)
				case "$key" in
				types) TYPES="$val" ;;
				production_branches) PRODUCTION_BRANCHES="$val" ;;
				strip_prefix) STRIP_PREFIX="$val" ;;
				hash_len) HASH_LEN="$val" ;;
				tag_prefix) TAG_PREFIX="$val" ;;
				subject_max) SUBJECT_MAX="$val" ;;
				esac
				CONF_SRC["$key"]="$file"
				;;
			*)
				_conf_warn "${file}:${lineno}: unknown key '${key}', skipped (known keys: ${_VERSIONER_KEYS} bump.<type> ignore_re)"
				;;
			esac
			;;
		esac
	done <"$file"
}

# Join the ignore regexes into one alternation so matching costs no forks.
_versioner_build_ignore_re() {
	local re out=""
	while IFS= read -r re; do
		[ -n "$re" ] || continue
		out="${out}${out:+|}(${re})"
	done <<<"$IGNORE_RES"
	IGNORE_RE_ALL="$out"
	if [ -n "$IGNORE_RE_ALL" ]; then
		local rc=0
		# shellcheck disable=SC2319  # $? here is the conditional's status, which is the point
		[[ "x" =~ $IGNORE_RE_ALL ]] 2>/dev/null || rc=$?
		# [[ =~ ]] returns 2 (not 1) when the pattern is not a valid ERE
		[ "$rc" -le 1 ] || _conf_die "ignore_re: invalid extended regex: ${IGNORE_RE_ALL}"
	fi
}

config_validate() {
	local t lvl src
	[ -n "$TYPES" ] || _conf_die "types: must not be empty"
	[ -n "$PRODUCTION_BRANCHES" ] || _conf_die "production_branches: must not be empty"
	[ -n "$TAG_PREFIX" ] || _conf_die "tag_prefix: must not be empty"
	for t in $TYPES; do
		case "$t" in
		*[!a-z]*) _conf_warn "${CONF_SRC[types]:-seed}: type '${t}' can never match the header grammar (types must be lowercase letters only)" ;;
		esac
	done
	case "$HASH_LEN" in
	'' | *[!0-9]*) _conf_die "${CONF_SRC[hash_len]:-seed}: hash_len must be an integer, got '${HASH_LEN}'" ;;
	esac
	if [ "$HASH_LEN" -lt 4 ] || [ "$HASH_LEN" -gt 40 ]; then
		_conf_die "${CONF_SRC[hash_len]:-seed}: hash_len must be between 4 and 40, got '${HASH_LEN}'"
	fi
	case "$SUBJECT_MAX" in
	'' | *[!0-9]*) _conf_die "${CONF_SRC[subject_max]:-seed}: subject_max must be an integer, got '${SUBJECT_MAX}'" ;;
	esac
	[ "$SUBJECT_MAX" -ge 1 ] || _conf_die "${CONF_SRC[subject_max]:-seed}: subject_max must be >= 1, got '${SUBJECT_MAX}'"
	for t in "${!BUMP_LEVEL_OF[@]}"; do
		lvl="${BUMP_LEVEL_OF[$t]}"
		src="${CONF_SRC[bump.${t}]:-seed}"
		case "$lvl" in
		major | minor | patch | noop) ;;
		*) _conf_die "${src}: bump.${t}: must be major|minor|patch|noop, got '${lvl}'" ;;
		esac
		# Only complain about mappings this repo wrote: the shipped defaults
		# map every stock type, and narrowing `types` must not produce a wall
		# of warnings about the ones that were dropped.
		if [ "$t" != breaking ] && ! type_is_whitelisted "$t" &&
			[ "${src#"${VERSIONER_HOME}/defaults/"}" = "$src" ]; then
			_conf_warn "${src}: bump.${t} has no effect: '${t}' is not in types"
		fi
	done
	[ -n "${BUMP_LEVEL_OF[breaking]:-}" ] || _conf_die "bump.breaking: must be defined"
}

config_load() {
	local f odir found=0
	for f in "$VERSIONER_HOME"/defaults/*.conf; do
		[ -e "$f" ] || continue
		found=1
		_versioner_read_conf_file "$f"
	done
	[ "$found" = 1 ] || _conf_die "no default policy found in ${VERSIONER_HOME}/defaults/*.conf (is the submodule checked out?)"
	odir="${VERSIONER_OVERRIDES_DIR:-$(dirname "$VERSIONER_HOME")/external-overrides}"
	VERSIONER_OVERRIDES_DIR_USED="$odir"
	if [ -d "$odir" ]; then
		for f in "$odir"/*.conf; do
			[ -e "$f" ] || continue
			_versioner_read_conf_file "$f"
		done
	fi
	_versioner_build_ignore_re
	config_validate
}

# Print the bump level (major|minor|patch|noop) for a type; empty if unmapped.
bump_for_type() {
	printf '%s' "${BUMP_LEVEL_OF[$1]:-}"
}

# True if $1 (a commit subject) matches any ignore regex.
config_is_ignored() {
	[ -n "$IGNORE_RE_ALL" ] || return 1
	[[ "$1" =~ $IGNORE_RE_ALL ]]
}

type_is_whitelisted() {
	case " $TYPES " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}
