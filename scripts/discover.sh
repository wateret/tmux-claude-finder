#!/usr/bin/env bash
# Discover live Claude Code sessions running in tmux panes.
# Outputs TSV: pane_target \t session_id \t cwd \t jsonl_path \t status \t name

set -euo pipefail

CLAUDE_SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-${HOME}/.claude/sessions}"
[ -d "$CLAUDE_SESSIONS_DIR" ] || CLAUDE_SESSIONS_DIR="${HOME}/.claude/sessions"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
[ -d "$CLAUDE_PROJECTS_DIR" ] || CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"

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

    # Single-pass awk: read SESSION_MAP, PANE_FILE, PS_FILE, then BFS through
    # the process tree per pane to find claude PIDs and join with session metadata.
    # Output is keyed by updatedAt so the trailing sort can order it.
    awk -v projects_dir="$CLAUDE_PROJECTS_DIR" '
        # Track which input file we are on. FNR resets to 1 at each new file,
        # so this fires once per file and must run before the per-file blocks.
        FNR == 1 { fileno++ }

        # File 1: SESSION_MAP (pid \t sessionId \t cwd \t status \t name \t updatedAt)
        fileno == 1 {
            split($0, s, "\t")
            spid = s[1]
            sid_by_pid[spid] = s[2]
            cwd_by_pid[spid] = s[3]
            status_by_pid[spid] = s[4]
            name_by_pid[spid] = s[5]
            updated_by_pid[spid] = s[6]
            next
        }
        # File 2: PANE_FILE (target|pane_pid|cwd|title)
        fileno == 2 {
            split($0, p, "|")
            pane_target[p[2]] = p[1]
            pane_title[p[2]] = p[4]
            pane_list[++pane_count] = p[2]
            next
        }
        # File 3: PS_FILE (pid ppid args)
        fileno == 3 {
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
                ptitle = pane_title[pane_list[i]]

                cpid = 0
                if (root in proc_tool && proc_tool[root] != "") {
                    cpid = root
                } else {
                    delete queue
                    qs = 1; qe = 0
                    if (root in child_list) {
                        nc = split(child_list[root], kids, SUBSEP)
                        for (j = 1; j <= nc; j++) {
                            k = kids[j]+0
                            if (k > 0) queue[++qe] = k
                        }
                    }
                    while (qs <= qe && cpid == 0) {
                        cur = queue[qs++]+0
                        if (cur in proc_tool && proc_tool[cur] != "") {
                            cpid = cur
                        }
                        if (cur in child_list) {
                            nc = split(child_list[cur], kids, SUBSEP)
                            for (j = 1; j <= nc; j++) {
                                k = kids[j]+0
                                if (k > 0) queue[++qe] = k
                            }
                        }
                    }
                }

                if (cpid == 0) continue
                cpids = cpid ""
                if (!(cpids in sid_by_pid) || sid_by_pid[cpids] == "") continue
                if (target in seen_target) continue
                seen_target[target] = 1

                sid = sid_by_pid[cpids]
                cwd = cwd_by_pid[cpids]
                sstatus = status_by_pid[cpids]
                sname = name_by_pid[cpids]
                supdated = updated_by_pid[cpids]

                project_folder = cwd
                gsub(/\//, "-", project_folder)
                jsonl_path = projects_dir "/" project_folder "/" sid ".jsonl"

                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                    supdated, target, sid, cwd, jsonl_path, sstatus, sname, ptitle
            }
        }
    ' "$SESSION_MAP" "$PANE_FILE" "$PS_FILE" | sort -t$'\t' -k1 -rn | cut -f2-
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
