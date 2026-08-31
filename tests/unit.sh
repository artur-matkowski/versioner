#!/usr/bin/env bash
# Unit tests: pure functions, no git repository, no forks.
# Run standalone (tests/unit.sh) or via tests/run.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

WORK="${WORK:-$(mktemp -d)}"
CLEAN_OV="$WORK/empty-overrides"
mkdir -p "$CLEAN_OV"

export VERSIONER_HOME="$ROOT"
export VERSIONER_OVERRIDES_DIR="$CLEAN_OV"
for _l in config commitlint history fold suffix changelog; do
	# shellcheck disable=SC1090
	. "$ROOT/bin/lib/${_l}.sh"
done
config_load

# Run `versioner config` with a given overrides dir; prints output, sets RC.
conf_run() { # <overrides-dir> [args...]
	local dir="$1"
	shift
	OUT="$(VERSIONER_OVERRIDES_DIR="$dir" "$ROOT/bin/versioner" config "$@" 2>&1)"
	RC=$?
}
ov_dir() { # <name> <content> -> prints dir
	local d="$WORK/ov-$1"
	rm -rf "$d"
	mkdir -p "$d"
	printf '%s\n' "$2" >"$d/00-test.conf"
	printf '%s' "$d"
}

# ---------------------------------------------------------------- defaults
if section 'defaults'; then
	assert_contains 'types include feat' 'feat' "$TYPES"
	assert_contains 'types include build' 'build' "$TYPES"
	assert_contains 'types include revert' 'revert' "$TYPES"
	assert_eq 'default hash_len' '7' "$HASH_LEN"
	assert_eq 'default subject_max' '72' "$SUBJECT_MAX"
	assert_eq 'default tag_prefix' 'v' "$TAG_PREFIX"
	assert_eq 'default production_branches' 'release/production' "$PRODUCTION_BRANCHES"
	assert_eq 'default strip_prefix' 'release/' "$STRIP_PREFIX"
	assert_eq 'bump.feat' 'minor' "$(bump_for_type feat)"
	assert_eq 'bump.fix' 'patch' "$(bump_for_type fix)"
	assert_eq 'bump.breaking' 'major' "$(bump_for_type breaking)"
	assert_eq 'bump.docs' 'noop' "$(bump_for_type docs)"
	assert_eq 'bump of unmapped type is empty' '' "$(bump_for_type nosuchtype)"
	# every whitelisted type must have a bump mapping, or it silently never bumps
	for t in $TYPES; do
		[ -n "$(bump_for_type "$t")" ] || fail 'every type has a bump mapping' "no bump.$t in defaults/bumpmap.conf"
	done
	ok 'every type has a bump mapping'
fi

# ---------------------------------------------------------------- ignore_re
if section 'ignore_re'; then
	assert_true 'ignores merge subjects' config_is_ignored "Merge branch 'x' into main"
	assert_true 'ignores release commits' config_is_ignored 'chore(release): v1.2.3'
	assert_true 'ignores reverts' config_is_ignored 'Revert "feat: x"'
	assert_false 'does not ignore a normal commit' config_is_ignored 'feat: x'
	assert_false 'anchored: not a merge mid-subject' config_is_ignored 'feat: Merge two configs'
fi

# ---------------------------------------------------------------- lint_header
if section 'lint_header'; then
	lh() { lint_header "$1" >/dev/null 2>&1; echo $?; }
	assert_exit 'plain feat' 0 "$(lh 'feat: add a thing')"
	assert_exit 'scoped' 0 "$(lh 'feat(api): add a thing')"
	assert_exit 'scoped with dots and dashes' 0 "$(lh 'fix(a.b-c_d): x')"
	assert_exit 'breaking bang' 0 "$(lh 'feat!: x')"
	assert_exit 'scoped breaking bang' 0 "$(lh 'feat(api)!: x')"
	assert_exit 'uppercase type rejected' 1 "$(lh 'Feat: x')"
	assert_exit 'missing space rejected' 1 "$(lh 'feat:x')"
	assert_exit 'missing colon rejected' 1 "$(lh 'feat x')"
	assert_exit 'empty subject rejected' 1 "$(lh 'feat: ')"
	assert_exit 'unknown type rejected' 1 "$(lh 'nope: x')"
	assert_exit 'trailing period rejected' 1 "$(lh 'feat: x.')"
	assert_exit 'bad scope char rejected' 1 "$(lh 'feat(bad scope): x')"
	assert_exit 'empty scope rejected' 1 "$(lh 'feat(): x')"
	assert_exit "subject of exactly subject_max ok" 0 "$(lh "feat: $(printf 'x%.0s' $(seq 1 "$SUBJECT_MAX"))")"
	assert_exit 'subject one over subject_max rejected' 1 "$(lh "feat: $(printf 'x%.0s' $(seq 1 $((SUBJECT_MAX + 1))))")"
	assert_contains 'names the offending type' 'unknown type "nope"' "$(lint_header 'nope: x')"
	assert_contains 'reports the length' 'subject exceeds 72' "$(lint_header "feat: $(printf 'x%.0s' $(seq 1 80))")"
fi

# ---------------------------------------------------------------- parse_bump
if section 'parse_bump'; then
	pb() { parse_bump "$1" "${2-}" >/dev/null 2>&1 && printf '%s' "${BUMP_LEVEL:-}" || printf 'NONE'; }
	assert_eq 'feat is minor' 'minor' "$(pb 'feat: x')"
	assert_eq 'fix is patch' 'patch' "$(pb 'fix: x')"
	assert_eq 'docs is noop' 'noop' "$(pb 'docs: x')"
	assert_eq 'bang is major' 'major' "$(pb 'fix!: x')"
	assert_eq 'non-conventional does not parse' 'NONE' "$(pb 'random words')"
	assert_eq 'unknown type does not parse' 'NONE' "$(pb 'nope: x')"
	assert_eq 'BREAKING CHANGE footer is major' 'major' \
		"$(pb 'fix: x' "$(printf 'fix: x\n\nBREAKING CHANGE: gone\n')")"
	assert_eq 'BREAKING-CHANGE footer is major' 'major' \
		"$(pb 'fix: x' "$(printf 'fix: x\n\nBREAKING-CHANGE: gone\n')")"
	assert_eq 'BREAKING CHANGE mid-line is not a footer' 'patch' \
		"$(pb 'fix: x' "$(printf 'fix: x\n\nwe avoid a BREAKING CHANGE: here\n')")"
	parse_bump 'feat(api)!: hello there' >/dev/null
	assert_eq 'parses type' 'feat' "$BUMP_TYPE"
	assert_eq 'parses scope' 'api' "$BUMP_SCOPE"
	assert_eq 'parses subject' 'hello there' "$BUMP_SUBJECT"
	assert_eq 'parses breaking flag' '1' "$BUMP_BREAKING"
fi

# ---------------------------------------------------------------- sanitize_branch
if section 'sanitize_branch'; then
	assert_eq 'strips strip_prefix' 'staging' "$(sanitize_branch 'release/staging')"
	assert_eq 'underscores become dashes' 'feature-test' "$(sanitize_branch 'release/feature_test')"
	assert_eq 'slashes become dashes' 'feat-x' "$(sanitize_branch 'feat/x')"
	assert_eq 'runs collapse' 'a-b' "$(sanitize_branch 'a///b')"
	assert_eq 'edges trimmed' 'a' "$(sanitize_branch '/a/')"
	assert_eq 'alnum kept' 'v2fix9' "$(sanitize_branch 'v2fix9')"
	assert_eq 'empty falls back' 'detached' "$(sanitize_branch '///')"
	assert_matches 'result is a legal semver identifier' '^[0-9A-Za-z-]+$' "$(sanitize_branch 'wéird/nàme!')"
	(
		STRIP_PREFIX=''
		assert_eq 'empty strip_prefix keeps the full name' 'release-staging' "$(sanitize_branch 'release/staging')"
	)
fi

# ---------------------------------------------------------------- is_production_branch
if section 'production_branches'; then
	assert_true 'default production branch' is_production_branch 'release/production'
	assert_false 'main is not production' is_production_branch 'main'
	(
		PRODUCTION_BRANCHES='release/production release/staging'
		assert_true 'second entry counts' is_production_branch 'release/staging'
		assert_false 'prefix is not a match' is_production_branch 'release/stagin'
	)
fi

# ---------------------------------------------------------------- config loader
if section 'config-loader'; then
	conf_run "$CLEAN_OV"
	assert_exit 'clean config loads' 0 "$RC"
	assert_contains 'reports the defaults dir' 'defaults/*.conf' "$OUT"

	conf_run "$(ov_dir inject 'path=/nonexistent')"
	assert_exit 'a key that is not policy cannot set a shell variable' 0 "$RC"
	assert_contains 'unknown key warns' "unknown key 'path'" "$OUT"

	conf_run "$(ov_dir dotted 'foo.bar=1')"
	assert_exit 'a dotted unknown key does not crash the tool' 0 "$RC"
	assert_contains 'dotted unknown key warns' "unknown key 'foo.bar'" "$OUT"

	conf_run "$(ov_dir badlevel 'bump.feat=Minor')"
	assert_exit 'a bump level typo is a config error' 2 "$RC"
	assert_contains 'names the bad level' 'bump.feat' "$OUT"

	conf_run "$(ov_dir badtype 'bump.feet=minor')"
	assert_exit 'a bump for an unknown type still loads' 0 "$RC"
	assert_contains 'but warns that it has no effect' 'bump.feet has no effect' "$OUT"

	conf_run "$(ov_dir badhash 'hash_len=abc')"
	assert_exit 'non-numeric hash_len is a config error' 2 "$RC"
	conf_run "$(ov_dir bighash 'hash_len=99')"
	assert_exit 'out-of-range hash_len is a config error' 2 "$RC"
	conf_run "$(ov_dir badsubj 'subject_max=notanumber')"
	assert_exit 'non-numeric subject_max is a config error' 2 "$RC"
	conf_run "$(ov_dir emptytypes 'types=')"
	assert_exit 'empty types is a config error' 2 "$RC"
	conf_run "$(ov_dir junk 'this is not a key=value line at all')"
	assert_exit 'a junk line does not stop the load' 0 "$RC"

	conf_run "$(ov_dir uppertype 'types=feat FIX')"
	assert_contains 'a type that cannot match the grammar warns' 'can never match' "$OUT"

	conf_run "$(ov_dir override 'hash_len=9
tag_prefix=rel-
subject_max=100')"
	assert_contains 'scalar override applies (hash_len)' '9' "$OUT"
	assert_contains 'scalar override applies (tag_prefix)' 'rel-' "$OUT"

	d="$(ov_dir ignreset "$(printf 'ignore_re=\nignore_re=^WIP')")"
	conf_run "$d" --json
	assert_contains 'ignore_re reset then set keeps only the new one' '"^WIP"' "$OUT"
	assert_not_contains 'ignore_re reset drops the defaults' '^Merge' "$OUT"

	d="$WORK/ov-layer"
	rm -rf "$d"
	mkdir -p "$d"
	printf 'bump.fix=major\n' >"$d/10-a.conf"
	printf 'bump.fix=noop\n' >"$d/20-b.conf"
	conf_run "$d" --json
	assert_contains 'later file wins' '"fix": "noop"' "$OUT"
fi

# ---------------------------------------------------------------- json
if section 'config-json'; then
	conf_run "$CLEAN_OV" --json
	assert_exit 'json config exits 0' 0 "$RC"
	if command -v python3 >/dev/null 2>&1; then
		assert_true 'config --json is valid JSON' python3 -c 'import json,sys;json.loads(sys.stdin.read())' <<<"$OUT"
	fi
	assert_contains 'json has the bump map' '"feat": "minor"' "$OUT"
	assert_contains 'json has ignore_re' '"^Merge"' "$OUT"
fi

summary 'unit'
