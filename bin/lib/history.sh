# shellcheck shell=bash
# versioner history walk
#
# One reader shared by the fold and the changelog. git emits one record per
# commit as
#     <sha>\x01<date>\x01<raw body>\x02\n
# so records are split on \x02 and the separating newline belongs to the NEXT
# record and must be stripped (getting this wrong silently corrupts the sha).
#
# Records are streamed with `read -d`, never accumulated into one string: the
# previous whole-string slicing was quadratic and dominated the runtime on any
# real history.

# history_each <ref> <callback>
# Calls: <callback> <sha> <short-date> <raw-message> for every commit reachable
# from <ref>, topological order, oldest first.
history_each() {
	local ref="$1" cb="$2" rec h date msg
	git rev-parse -q --verify "${ref}^{commit}" >/dev/null || {
		printf 'versioner: unknown ref: %s\n' "$ref" >&2
		return 1
	}
	while IFS= read -r -d $'\x02' rec; do
		rec="${rec#$'\n'}"
		h="${rec%%$'\x01'*}"
		rec="${rec#*$'\x01'}"
		date="${rec%%$'\x01'*}"
		msg="${rec#*$'\x01'}"
		msg="${msg//$'\r'/}"
		"$cb" "$h" "$date" "$msg"
	done < <(git log --topo-order --reverse --date=short --format="%H%x01%ad%x01%B%x02" "$ref")
}
