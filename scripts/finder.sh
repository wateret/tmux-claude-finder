#!/usr/bin/env bash
# Main orchestrator for tmux-claude-finder.
# Discovers live sessions, opens fzf popup, switches to selected pane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for cmd in rg fzf jq; do
    if ! command -v "$cmd" &>/dev/null; then
        tmux display-message "tmux-claude-finder: '$cmd' not found. Install it first."
        exit 1
    fi
done

POPUP_COLS=$(tput cols 2>/dev/null || echo 120)
export POPUP_COLS

POPUP_LINES="${LINES:-$(tput lines 2>/dev/null || echo 24)}"
PREVIEW_LINES=$(( POPUP_LINES * 50 / 100 ))
[ "$PREVIEW_LINES" -lt 3 ]  && PREVIEW_LINES=3
[ "$PREVIEW_LINES" -gt 10 ] && PREVIEW_LINES=10
# Don't let the cap push preview above 50% of the actual popup height
[ "$PREVIEW_LINES" -gt $(( POPUP_LINES / 2 )) ] && PREVIEW_LINES=$(( POPUP_LINES / 2 ))
[ "$PREVIEW_LINES" -lt 3 ]  && PREVIEW_LINES=3

DISCOVER_FILE=$(mktemp)
trap 'rm -f "$DISCOVER_FILE"' EXIT INT TERM

SEARCH_CMD="$SCRIPT_DIR/search.sh"

# discover.sh emits TSV; save raw lines for search reloads, then let search.sh
# render the initial (empty-query) display so formatting lives in one place.
"$SCRIPT_DIR/discover.sh" >"$DISCOVER_FILE"

selected=$(
    "$SEARCH_CMD" "" "$DISCOVER_FILE" | \
    fzf --ansi \
        --prompt="Search sessions> " \
        --bind "change:reload:$SEARCH_CMD {q} $DISCOVER_FILE" \
        --preview-window="down:${PREVIEW_LINES}:wrap" \
        --preview="$SCRIPT_DIR/preview.sh {1} {q} $DISCOVER_FILE" \
        --layout=reverse \
    || true
)

if [ -z "$selected" ]; then
    exit 0
fi

# Extract pane target (first 12 chars, trimmed)
pane_target=$(echo "$selected" | cut -c1-12 | xargs)

if [ -n "$pane_target" ]; then
    tmux switch-client -t "$pane_target" 2>/dev/null || \
        tmux select-pane -t "$pane_target" 2>/dev/null || \
        tmux display-message "Cannot switch to pane: $pane_target"
fi
