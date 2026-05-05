#!/usr/bin/env bash
# Search live Claude Code session transcripts.
# Usage: search.sh <query> <discover_tsv_file>
# If query is empty, lists all sessions. Otherwise searches with rg.

set -euo pipefail

QUERY="${1:-}"
DISCOVER_FILE="${2:-}"

# Fast-path size: only the most recent N matches per session are sent through jq.
# If they all fail to yield a snippet, we fall back to scanning all matches.
SEARCH_FAST_LIMIT="${SEARCH_FAST_LIMIT:-50}"

if [ -z "$DISCOVER_FILE" ] || [ ! -f "$DISCOVER_FILE" ]; then
	exit 0
fi

if [ -z "$QUERY" ]; then
	while IFS=$'\t' read -r pane session_id cwd jsonl_path sstatus session_name ptitle; do
		[ -z "$pane" ] && continue
		local_cwd="${cwd##*/}"
		[ -z "$local_cwd" ] && local_cwd="$cwd"
		clean_title=$(printf '%s' "$ptitle" | sed 's/^[^a-zA-Z0-9]* *//')
		printf '%-12s %-9s %-16s [%-4s] %s\n' "$pane" "${session_id:0:8}" "$local_cwd" "$sstatus" "$clean_title"
	done <"$DISCOVER_FILE"
	exit 0
fi

declare -A PANE_MAP CWD_MAP SID_MAP
JSONL_FILES=()

while IFS=$'\t' read -r pane session_id cwd jsonl_path sstatus session_name ptitle; do
	[ -z "$pane" ] && continue
	if [ -f "$jsonl_path" ]; then
		PANE_MAP["$jsonl_path"]="$pane"
		SID_MAP["$jsonl_path"]="${session_id:0:8}"
		CWD_MAP["$jsonl_path"]="${cwd##*/}"
		JSONL_FILES+=("$jsonl_path")
	fi
done <"$DISCOVER_FILE"

if [ ${#JSONL_FILES[@]} -eq 0 ]; then
	exit 0
fi

# Per-session worker. Reads from a single jsonl, writes one display line
# (or nothing) to stdout. Called in parallel via xargs -P below.
# Each call receives: <seq>\t<pane>\t<sid>\t<cwd_short>\t<jsonl_path>
# A leading sequence number lets us re-sort xargs' interleaved output back
# to the original updatedAt-descending order.
process_session() {
	local seq pane sid cwd_short match_file
	IFS=$'\t' read -r seq pane sid cwd_short match_file <<<"$1"

	local jq_extract='
		def extract_text:
			if (.message | type) == "string" then .message
			elif (.message.content | type) == "string" then .message.content
			elif (.message.content | type) == "array" then
				[.message.content[] |
					if .type == "text" then .text
					elif .type == "tool_use" then
						(.input | values | map(tostring) | join(" "))
					elif .type == "tool_result" then
						(.content // [] | map(select(.type == "text") | .text) | join(" "))
					else ""
					end
				] | map(select(length > 0)) | join(" ")
			else ""
			end;
		extract_text | gsub("\\n"; " ") | gsub("\\\\n"; " ") |
		[match("(.{0,40}" + $q + ".{0,40})"; "ig")] | .[0].string // ""
	'

	local text
	text=$(rg -i --no-filename '"type"\s*:\s*"(user|assistant)"' "$match_file" 2>/dev/null | \
		rg -i -- "$QUERY" 2>/dev/null | \
		tail -"$SEARCH_FAST_LIMIT" | \
		jq -r --arg q "$QUERY" "$jq_extract" 2>/dev/null | rg -v '^$' | tail -1 || true)

	if [ -z "$text" ]; then
		text=$(rg -i --no-filename '"type"\s*:\s*"(user|assistant)"' "$match_file" 2>/dev/null | \
			rg -i -- "$QUERY" 2>/dev/null | \
			jq -r --arg q "$QUERY" "$jq_extract" 2>/dev/null | rg -v '^$' | tail -1 || true)
	fi

	[ -z "$text" ] && return 0

	text=$(printf '%s' "$text" | sed 's/\\t/ /g; s/  */ /g')
	if [ ${#text} -gt 80 ]; then
		text="${text:0:77}..."
	fi

	# Emit "<seq>\t<formatted line>" so the caller can sort by seq.
	printf '%s\t%-12s %-9s %-16s %s\n' "$seq" "$pane" "$sid" "$cwd_short" "$text"
}
export -f process_session
export QUERY SEARCH_FAST_LIMIT

# Build the set of files that match $QUERY. ripgrep's --sort=none (default)
# is multi-threaded with non-deterministic ordering, so we use rg -l only as
# a membership filter and walk JSONL_FILES ourselves to preserve the
# updatedAt-descending order coming from discover.sh.
matching_files=$(rg -i -l -- "$QUERY" "${JSONL_FILES[@]}" 2>/dev/null || true)
declare -A MATCHED
while IFS= read -r f; do
	[ -n "$f" ] && MATCHED["$f"]=1
done <<<"$matching_files"

# Build TSV in JSONL_FILES order: <seq>\t<pane>\t<sid>\t<cwd>\t<jsonl_path>
seq=0
tsv=""
declare -A SEEN_PANE
for path in "${JSONL_FILES[@]}"; do
	[ -z "${MATCHED[$path]:-}" ] && continue
	pane="${PANE_MAP[$path]:-}"
	[ -z "$pane" ] && continue
	[ -n "${SEEN_PANE[$pane]:-}" ] && continue
	SEEN_PANE["$pane"]=1
	seq=$((seq + 1))
	# Pad seq so lexicographic sort works without -n (faster, smaller binary).
	tsv+=$(printf '%05d\t%s\t%s\t%s\t%s\n' "$seq" "$pane" "${SID_MAP[$path]:-}" "${CWD_MAP[$path]:-}" "$path")
	tsv+=$'\n'
done

[ -z "$tsv" ] && exit 0

# Run process_session in parallel; -P 0 lets xargs use as many workers as
# there are tasks (xargs caps it at the number of input items anyway).
# Then sort by sequence number to restore updatedAt order, drop the seq column.
printf '%s\n' "$tsv" | xargs -d '\n' -I{} -P 0 bash -c 'process_session "$@"' _ {} | \
	sort -t$'\t' -k1,1n | cut -f2-
