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

# Column layout: pane(12) + space + sid(9) + space + cwd(16) + space = 40 fixed chars.
# TEXT_MAX is the remaining width available for the match snippet.
# CONTEXT_CHARS is how many chars to show on each side of the matched query.
POPUP_COLS="${POPUP_COLS:-$(tput cols 2>/dev/null || echo 120)}"
TEXT_MAX=$(( POPUP_COLS - 40 ))
if [ "${#QUERY}" -ge "$TEXT_MAX" ]; then
    # Query fills or exceeds available space: show just the query, no context, no truncation
    CONTEXT_CHARS=0
else
    CONTEXT_CHARS=$(( (TEXT_MAX - ${#QUERY}) / 2 ))
fi

if [ -z "$DISCOVER_FILE" ] || [ ! -f "$DISCOVER_FILE" ]; then
    exit 0
fi

if [ -z "$QUERY" ]; then
    while IFS=$'\t' read -r pane session_id cwd jsonl_path sstatus session_name ptitle; do
        [ -z "$pane" ] && continue
        local_cwd="${cwd##*/}"
        [ -z "$local_cwd" ] && local_cwd="$cwd"
        [ ${#local_cwd} -gt 16 ] && local_cwd="${local_cwd:0:15}…"
        clean_title=$(printf '%s' "$ptitle" | sed 's/^[^a-zA-Z0-9]* *//')
        s="${sstatus:0:4}"
        case "$sstatus" in
            busy)    status_col=$(printf '\033[35m[%-4s]\033[0m' "$s") ;;
            idle)    status_col=$(printf '\033[90m[%-4s]\033[0m' "$s") ;;
            shell)   status_col=$(printf '\033[34m[%-4s]\033[0m' "$s") ;;
            waiting) status_col=$(printf '\033[33m[%-4s]\033[0m' "$s") ;;
            *)       status_col=$(printf '[%-4s]' "$s") ;;
        esac
        printf '%-12s %-9s %-16s %s %s\n' "$pane" "${session_id:0:8}" "$local_cwd" "$status_col" "$clean_title"
    done <"$DISCOVER_FILE"
    exit 0
fi

declare -a JSONL_FILES=()

while IFS=$'\t' read -r pane session_id cwd jsonl_path sstatus session_name ptitle; do
    [ -z "$pane" ] && continue
    if [ -f "$jsonl_path" ]; then
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
        [match("(.{0," + $ctx + "}" + $q + ".{0," + $ctx + "})"; "ig")] | .[0].string // ""
    '

    local text
    text=$(rg -i --no-filename '"type"\s*:\s*"(user|assistant)"' "$match_file" 2>/dev/null | \
        rg -i -- "$QUERY" 2>/dev/null | \
        tail -"$SEARCH_FAST_LIMIT" | \
        jq -r --arg q "$QUERY" --arg ctx "$CONTEXT_CHARS" "$jq_extract" 2>/dev/null | rg -v '^$' | tail -1 || true)

    if [ -z "$text" ]; then
        text=$(rg -i --no-filename '"type"\s*:\s*"(user|assistant)"' "$match_file" 2>/dev/null | \
            rg -i -- "$QUERY" 2>/dev/null | \
            jq -r --arg q "$QUERY" --arg ctx "$CONTEXT_CHARS" "$jq_extract" 2>/dev/null | rg -v '^$' | tail -1 || true)
    fi

    [ -z "$text" ] && return 0

    text=$(printf '%s' "$text" | sed 's/\\t/ /g; s/  */ /g')
    if [ "$CONTEXT_CHARS" -gt 0 ] && [ ${#text} -gt "$TEXT_MAX" ]; then
        text="${text:0:$(( TEXT_MAX - 3 ))}..."
    fi

    # Emit "<seq>\t<formatted line>" so the caller can sort by seq.
    printf '%s\t%-12s %-9s %-16s %s\n' "$seq" "$pane" "$sid" "$cwd_short" "$text"
}
export -f process_session
export QUERY SEARCH_FAST_LIMIT CONTEXT_CHARS TEXT_MAX

# Build the set of files that match $QUERY. ripgrep's --sort=none (default)
# is multi-threaded with non-deterministic ordering, so we use rg -l only as
# a membership filter; the awk below walks DISCOVER_FILE in order to preserve
# the updatedAt-descending sequence coming from discover.sh.
MATCHED_FILE=$(mktemp)
trap 'rm -f "$MATCHED_FILE"' EXIT INT TERM
rg -i -l -- "$QUERY" "${JSONL_FILES[@]}" >"$MATCHED_FILE" 2>/dev/null || true

# Join MATCHED_FILE (paths matching $QUERY) with DISCOVER_FILE to produce
# the parallel-job TSV. Dedupes by pane, preserves DISCOVER_FILE order, and
# stamps a zero-padded seq so a lexicographic sort restores order later.
tsv=$(awk -F'\t' '
    FNR == 1 { fileno++ }
    fileno == 1 { matched[$0] = 1; next }
    fileno == 2 {
        pane = $1; sid = $2; cwd = $3; jsonl_path = $4
        if (pane == "" || jsonl_path == "" || !(jsonl_path in matched)) next
        if (pane in seen_pane) next
        seen_pane[pane] = 1

        short_sid = substr(sid, 1, 8)
        n = split(cwd, parts, "/")
        short_cwd = parts[n]
        if (short_cwd == "") short_cwd = cwd
        if (length(short_cwd) > 16) short_cwd = substr(short_cwd, 1, 15) "…"

        seq++
        printf "%05d\t%s\t%s\t%s\t%s\n", seq, pane, short_sid, short_cwd, jsonl_path
    }
' "$MATCHED_FILE" "$DISCOVER_FILE")

[ -z "$tsv" ] && exit 0

# Run process_session in parallel; -P 0 lets xargs use as many workers as
# there are tasks (xargs caps it at the number of input items anyway).
# Use NUL-delimited input via -0 (portable across BSD and GNU xargs;
# -d is GNU-only). Then sort by seq to restore updatedAt order.
printf '%s\n' "$tsv" | tr '\n' '\0' | xargs -0 -I{} -P 0 bash -c 'process_session "$@"' _ {} | \
    sort -t$'\t' -k1,1n | cut -f2-
