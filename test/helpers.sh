#!/usr/bin/env bash
# Shared test helpers for tmux-claude-finder tests

_PASS=0
_FAIL=0

pass() { _PASS=$((_PASS + 1)); echo "  PASS: $1"; }
fail() { _FAIL=$((_FAIL + 1)); echo "  FAIL: $1"; }

summary() {
	echo ""
	echo "Results: $_PASS passed, $_FAIL failed"
	[ "$_FAIL" -gt 0 ] && return 1
	return 0
}

# Paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"
FIXTURES_DIR="$TEST_DIR/fixtures"

export CLAUDE_SESSIONS_DIR="$FIXTURES_DIR/sessions"
export CLAUDE_PROJECTS_DIR="$FIXTURES_DIR/projects"
