#!/usr/bin/env bash
# Wire versioner into the surrounding (parent) repo. Idempotent: run it again
# after `git submodule update --remote` and it will report everything as
# already present.
#
# Writes into the PARENT repo only — never into the submodule:
#   .git/hooks/commit-msg                          (via install.sh)
#   .gitea/workflows/versioner-*.yml               (thin triggers)
#   external-overrides/00-policy.conf.example      (policy skeleton)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=0
CREATED=0
SKIPPED=0

for a in "$@"; do
	case "$a" in
	--force) FORCE=1 ;;
	*)
		printf 'versioner: init: unknown option: %s\n' "$a" >&2
		exit 2
		;;
	esac
done

git rev-parse --git-dir >/dev/null 2>&1 || {
	printf 'versioner: init: not inside a git repository\n' >&2
	exit 2
}
TOPLEVEL="$(git rev-parse --show-toplevel)"

case "$ROOT/" in
"$TOPLEVEL"/*) REL="${ROOT#"$TOPLEVEL"/}" ;;
*)
	printf 'versioner: init: %s is not inside %s — add versioner as a submodule of this repo first\n' "$ROOT" "$TOPLEVEL" >&2
	exit 2
	;;
esac

if [ "$TOPLEVEL" = "$ROOT" ]; then
	printf 'versioner: init: refusing to wire versioner into itself\n' >&2
	exit 2
fi

write_file() { # <path-relative-to-toplevel> <content>
	local path="${TOPLEVEL}/$1" content="$2"
	if [ -e "$path" ] && [ "$FORCE" != 1 ]; then
		printf '  skip    %s (exists; --force to overwrite)\n' "$1"
		SKIPPED=$((SKIPPED + 1))
		return 0
	fi
	mkdir -p "$(dirname "$path")"
	printf '%s' "$content" >"$path"
	printf '  write   %s\n' "$1"
	CREATED=$((CREATED + 1))
}

printf 'versioner: wiring %s into %s\n\n' "$REL" "$TOPLEVEL"

printf 'hook:\n'
if [ "$FORCE" = 1 ]; then
	bash "${ROOT}/install.sh" --force | sed 's/^versioner: /  /'
else
	bash "${ROOT}/install.sh" | sed 's/^versioner: /  /'
fi

printf '\nCI workflows (thin triggers; the logic stays in %s/ci/):\n' "$REL"
for f in "${ROOT}"/ci/gitea/*.yml; do
	[ -e "$f" ] || continue
	name="$(basename "$f")"
	content="$(cat "$f")"
	write_file ".gitea/workflows/versioner-${name}" "${content//.\/versioner\//./${REL}/}"$'\n'
done

printf '\npolicy overrides (tracked by THIS repo, not the submodule):\n'
write_file 'external-overrides/00-policy.conf.example' "$(
	cat <<POLICY
# versioner policy overrides for this repo. Copy to 00-policy.conf and edit.
# Files are read in alphabetical order; later files and later lines win.
# Run \`./${REL}/bin/versioner config\` to see what is actually in effect.

# Commit types accepted by lint (space separated). Anything else fails lint.
#types=feat fix chore docs refactor perf test style ci build revert

# Version bump per type; bump.breaking applies to "type!:" and BREAKING CHANGE.
#bump.feat=minor
#bump.fix=patch
#bump.breaking=major
#bump.perf=patch

# Subjects matching these EREs are skipped by the hook, the PR gate, the version
# fold and the changelog. Each line appends; a bare "ignore_re=" resets the list.
#ignore_re=^WIP

# Branches whose commits print a bare X.Y.Z instead of X.Y.Z-<branch>.<hash>.
#production_branches=release/production

# Prefix stripped from the branch name before it is sanitized into the suffix.
#strip_prefix=release/

# Commit hash length in the suffix (4-40).
#hash_len=7

# Prefix for version tags.
#tag_prefix=v

# Max commit subject length enforced by lint.
#subject_max=72
POLICY
)"$'\n'

printf '\ndone: %s written, %s already present\n' "$CREATED" "$SKIPPED"
cat <<SNIPPET

Add this to the parent repo's CLAUDE.md / AGENTS.md so an agent can find it:

  ## Versioning
  Commit messages, versions, CHANGELOG.md and release tags in this repo are
  governed by \`versioner\`, a git submodule at \`./${REL}\`.
  Read \`./${REL}/AGENTS.md\` before changing commit conventions, CI, or
  anything under \`external-overrides/\`. Commit messages must be Conventional
  Commits (\`type(scope)!: subject\`); \`./${REL}/bin/versioner config\` prints
  the policy actually in effect.

Then commit the files above (the submodule itself stays untouched):
  git add .gitea external-overrides && git commit -m 'ci: wire in versioner'
SNIPPET
