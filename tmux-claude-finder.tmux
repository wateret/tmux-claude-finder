#!/usr/bin/env bash
# tmux-claude-finder plugin entry point.
# Registers a key binding to open the Claude Code session finder.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
	local key
	key=$(tmux show-option -gqv @claude-finder-key 2>/dev/null || true)
	key="${key:-F}"

	local popup_width
	popup_width=$(tmux show-option -gqv @claude-finder-popup-width 2>/dev/null || true)
	popup_width="${popup_width:-80%}"

	local popup_height
	popup_height=$(tmux show-option -gqv @claude-finder-popup-height 2>/dev/null || true)
	popup_height="${popup_height:-60%}"

	local user_shell
	user_shell=$(tmux show-option -gqv default-shell 2>/dev/null || true)
	user_shell="${user_shell:-${SHELL:-/bin/sh}}"

	tmux bind-key "$key" display-popup \
		-w "$popup_width" -h "$popup_height" \
		-E "$user_shell -lic '$CURRENT_DIR/scripts/finder.sh'"
}

main
