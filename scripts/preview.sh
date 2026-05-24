#!/usr/bin/env bash
# Preview script for fzf: shows matching messages with timestamps.
# Usage: preview.sh <pane_target> <query> <discover_file>

set -euo pipefail

PANE="${1:-}"
QUERY="${2:-}"
DISCOVER_FILE="${3:-}"

if [ -z "$PANE" ] || [ -z "$DISCOVER_FILE" ] || [ ! -f "$DISCOVER_FILE" ]; then
    exit 0
fi

# Find the JSONL path for this pane
jsonl_path=""
while IFS=$'\t' read -r p sid cwd path sstatus sname ptitle; do
    if [ "$p" = "$PANE" ]; then
        jsonl_path="$path"
        break
    fi
done <"$DISCOVER_FILE"

if [ -z "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; then
    echo "(no transcript found)"
    exit 0
fi

# Fixed overhead per row: timestamp(11) + "  "(2) + "["(1) + type(4) + "]"(1) + "  "(2) = 21
PREVIEW_COLS="${FZF_PREVIEW_COLUMNS:-${POPUP_COLS:-120}}"
_PREVIEW_TEXT_MAX=$(( PREVIEW_COLS - 21 ))
if [ "${#QUERY}" -ge "$_PREVIEW_TEXT_MAX" ]; then
    # Query fills or exceeds available space: show just the query, no context
    CONTEXT_CHARS=0
else
    CONTEXT_CHARS=$(( (_PREVIEW_TEXT_MAX - ${#QUERY}) / 2 ))
fi

if [ -z "$QUERY" ]; then
    # Show last prompt from this session
    last_prompt=$(tail -20 "$jsonl_path" | jq -r 'select(.type == "last-prompt") | .lastPrompt // empty' 2>/dev/null | tail -1)
    if [ -n "$last_prompt" ]; then
        echo "Last prompt: $last_prompt"
    else
        echo "(no recent prompt)"
    fi
    exit 0
fi

# Find matching user/assistant messages, extract timestamp + content
result=$(rg -i --no-filename '"type"\s*:\s*"(user|assistant)"' "$jsonl_path" 2>/dev/null | \
    rg -i -- "$QUERY" 2>/dev/null | \
    jq -r '
        def local_time: if . == null or . == "?" then "?" else (.[0:19] + "Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | localtime | strftime("%m-%d %H:%M")) end;
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

        def short_type: if . == "assistant" then " ai " elif . == "user" then "user" else (.[0:4] + "    ")[0:4] end;

        "\(.timestamp // "?" | local_time)  [\(.type // "?" | short_type | .[:4])]  \(extract_text | gsub("\\n"; " ") | gsub("\\\\n"; " ") | [match("(.{0," + $ctx + "}" + $q + ".{0," + $ctx + "})"; "ig")] | .[0].string // "")"
    ' --arg q "$QUERY" --arg ctx "$CONTEXT_CHARS" 2>/dev/null | \
    grep -i --color=always -- "$QUERY" 2>/dev/null | tail -10 | tac || true)

if [ -n "$result" ]; then
    echo "$result"
else
    # Fallback: show timestamp + type + context around the match
    rg -i --no-filename -- "$QUERY" "$jsonl_path" 2>/dev/null | tail -10 | \
        jq -r --arg q "$QUERY" '
            def local_time: if . == null or . == "?" then "?" else (.[0:19] + "Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | localtime | strftime("%m-%d %H:%M")) end;
            def short_type: if . == "assistant" then " ai " elif . == "user" then "user" else (.[0:4] + "    ")[0:4] end;
            def snippet: tostring | [match("(.{0," + $ctx + "}" + $q + ".{0," + $ctx + "})"; "ig")] | .[0].string // "";
            "\(.timestamp // "?" | local_time)  [\(.type // "?" | short_type | .[:4])]  \(snippet | gsub("\\\\n"; " ") | gsub("\\\\t"; " "))"
        ' --arg ctx "$CONTEXT_CHARS" 2>/dev/null | \
        grep -i --color=always -- "$QUERY" 2>/dev/null | \
        tac | head -10 || echo "(no matches)"
fi
