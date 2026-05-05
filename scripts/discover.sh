#!/usr/bin/env bash
# Discover live Claude Code sessions running in tmux panes.
# Outputs TSV: pane_target \t session_id \t cwd \t jsonl_path \t status \t name

set -euo pipefail

CLAUDE_SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-${HOME}/.claude/sessions}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"

PS_FILE=$(mktemp)
PANE_FILE=$(mktemp)
SESSION_MAP=$(mktemp)
trap 'rm -f "$PS_FILE" "$PANE_FILE" "$SESSION_MAP"' EXIT INT TERM

main() {
	if [ -n "${MOCK_PS_FILE:-}" ] && [ -f "$MOCK_PS_FILE" ]; then
		cp "$MOCK_PS_FILE" "$PS_FILE"
	else
		ps -eo pid=,ppid=,args= >"$PS_FILE" 2>/dev/null
	fi
	if [ ! -s "$PS_FILE" ]; then
		exit 0
	fi

	if [ -n "${MOCK_PANE_FILE:-}" ] && [ -f "$MOCK_PANE_FILE" ]; then
		cp "$MOCK_PANE_FILE" "$PANE_FILE"
	else
		tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}|#{pane_title}" >"$PANE_FILE" 2>/dev/null
	fi
	if [ ! -s "$PANE_FILE" ]; then
		exit 0
	fi

	# Read all session files in one jq call — keyed by PID, sorted by updatedAt desc
	jq -r '
		select(.kind == "interactive") |
		[(.pid | tostring), .sessionId // "", .cwd // "", .status // "unknown", .name // "-", (.updatedAt // 0 | tostring)] |
		join("\t")
	' "$CLAUDE_SESSIONS_DIR"/*.json 2>/dev/null | sort -t$'\t' -k6 -rn >"$SESSION_MAP" || true

	if [ ! -s "$SESSION_MAP" ]; then
		exit 0
	fi

	# BFS through process tree to find claude PIDs per pane
	local MATCHES
	MATCHES=$(awk '
		NR == FNR {
			split($0, p, "|")
			pane_target[p[2]] = p[1]
			pane_title[p[2]] = p[4]
			pane_list[++pane_count] = p[2]
			next
		}
		{
			pid = $1+0; ppid = $2+0
			line = $0
			sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)

			child_list[ppid] = (ppid in child_list) ? child_list[ppid] SUBSEP pid : "" pid

			if (line ~ /(^claude( |$)|\/claude( |$))/) proc_tool[pid] = "claude"
		}
		END {
			for (i = 1; i <= pane_count; i++) {
				root = pane_list[i]+0
				target = pane_target[pane_list[i]]

				if (root in proc_tool && proc_tool[root] != "") {
					printf "%s\t%d\t%s\n", target, root, pane_title[pane_list[i]]
					continue
				}

				delete queue
				qs = 1; qe = 0
				if (root in child_list) {
					nc = split(child_list[root], kids, SUBSEP)
					for (j = 1; j <= nc; j++) {
						k = kids[j]+0
						if (k > 0) { queue[++qe] = k }
					}
				}

				found = 0
				while (qs <= qe && !found) {
					cur = queue[qs++]+0
					if (cur in proc_tool && proc_tool[cur] != "") {
						printf "%s\t%d\t%s\n", target, cur, pane_title[pane_list[i]]
						found = 1
					}
					if (cur in child_list) {
						nc = split(child_list[cur], kids, SUBSEP)
						for (j = 1; j <= nc; j++) {
							k = kids[j]+0
							if (k > 0) { queue[++qe] = k }
						}
					}
				}
			}
		}
	' "$PANE_FILE" "$PS_FILE")

	if [ -z "$MATCHES" ]; then
		exit 0
	fi

	# Join pane→pid matches with session metadata
	# SESSION_MAP is: pid \t sessionId \t cwd \t status \t name \t updatedAt
	declare -A SID_BY_PID CWD_BY_PID STATUS_BY_PID NAME_BY_PID UPDATED_BY_PID
	while IFS=$'\t' read -r spid sid scwd sstatus sname supdated; do
		SID_BY_PID["$spid"]="$sid"
		CWD_BY_PID["$spid"]="$scwd"
		STATUS_BY_PID["$spid"]="$sstatus"
		NAME_BY_PID["$spid"]="$sname"
		UPDATED_BY_PID["$spid"]="$supdated"
	done <"$SESSION_MAP"

	local resolved_targets=""
	local RESULTS=""
	while IFS=$'\t' read -r target cpid ptitle; do
		[ -z "$target" ] && continue

		case "$resolved_targets" in
		*"|${target}|"*) continue ;;
		esac

		local session_id="${SID_BY_PID[$cpid]:-}"
		if [ -z "$session_id" ]; then
			continue
		fi

		local cwd="${CWD_BY_PID[$cpid]:-}"
		local sstatus="${STATUS_BY_PID[$cpid]:-unknown}"
		local sname="${NAME_BY_PID[$cpid]:-}"
		local supdated="${UPDATED_BY_PID[$cpid]:-0}"

		local project_folder
		project_folder=$(echo "$cwd" | tr '/' '-')
		local jsonl_path="$CLAUDE_PROJECTS_DIR/${project_folder}/${session_id}.jsonl"

		RESULTS="${RESULTS}${supdated}\t${target}\t${session_id}\t${cwd}\t${jsonl_path}\t${sstatus}\t${sname}\t${ptitle}\n"
		resolved_targets="${resolved_targets}|${target}|"
	done <<<"$MATCHES"

	# Sort by updatedAt descending, then strip the sort key
	printf '%b' "$RESULTS" | sort -t$'\t' -k1 -rn | cut -f2-
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
