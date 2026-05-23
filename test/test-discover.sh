#!/usr/bin/env bash
# Tests for discover.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

echo "Testing discover.sh..."

MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# --- Mock data ---
# ps output: pid ppid args
# PID 12345 is a claude process (child of pane pid 100)
# PID 67890 is a claude process (child of pane pid 200)
# PID 99999 is not claude
cat >"$MOCK_DIR/ps.txt" <<'EOF'
  100     1 bash
12345   100 claude --session aaaa-bbbb
  200     1 zsh
67890   200 /usr/local/bin/claude
  300     1 bash
99999   300 vim
EOF

# tmux pane output: session:window.pane|pane_pid|cwd|title
cat >"$MOCK_DIR/panes.txt" <<'EOF'
main:0.0|100|/test/project|fix muffin bug
work:1.0|200|/test/other|refactor fleet
idle:2.0|300|/somewhere|editing
EOF

export MOCK_PS_FILE="$MOCK_DIR/ps.txt"
export MOCK_PANE_FILE="$MOCK_DIR/panes.txt"

# Test: discovers interactive sessions
output=$("$PROJECT_DIR/scripts/discover.sh")
if echo "$output" | rg -q "main:0.0"; then
    pass "discovers session in main:0.0"
else
    fail "discovers session in main:0.0 (got: $output)"
fi

if echo "$output" | rg -q "work:1.0"; then
    pass "discovers session in work:1.0"
else
    fail "discovers session in work:1.0 (got: $output)"
fi

# Test: filters out non-claude panes
if echo "$output" | rg -q "idle:2.0"; then
    fail "should not include non-claude pane idle:2.0"
else
    pass "filters out non-claude pane"
fi

# Test: filters out subagent sessions
if echo "$output" | rg -q "eeee-ffff"; then
    fail "should not include subagent session"
else
    pass "filters out subagent session"
fi

# Test: output contains session IDs
if echo "$output" | rg -q "aaaa-bbbb"; then
    pass "output contains session ID aaaa-bbbb"
else
    fail "output contains session ID aaaa-bbbb (got: $output)"
fi

# Test: output contains JSONL paths
if echo "$output" | rg -q "aaaa-bbbb.jsonl"; then
    pass "output contains JSONL path"
else
    fail "output contains JSONL path (got: $output)"
fi

# Test: sorted by updatedAt descending (cccc-dddd has higher updatedAt)
first_line=$(echo "$output" | head -1)
if echo "$first_line" | rg -q "cccc-dddd"; then
    pass "sorted by updatedAt descending (most recent first)"
else
    fail "sorted by updatedAt descending (first line: $first_line)"
fi

# Test: two claude processes in different panes with the same session
# (e.g., claude resumed/forked — both PIDs map to the same sessionId)
cat >"$MOCK_DIR/ps_dupsession.txt" <<'EOF'
  100     1 bash
12345   100 claude --session aaaa-bbbb
  200     1 zsh
12346   200 claude --resume aaaa-bbbb
EOF

cat >"$MOCK_DIR/panes_dupsession.txt" <<'EOF'
pane1:0.0|100|/test/project|fix muffin bug
pane2:1.0|200|/test/project|fix muffin bug
EOF

# Need a session JSON for pid 12346 with the same sessionId
cat >"$FIXTURES_DIR/sessions/12346.json" <<'EOF'
{"pid":12346,"sessionId":"aaaa-bbbb","cwd":"/test/project","status":"active","kind":"interactive","name":"fix muffin bug","updatedAt":1700000150000}
EOF

export MOCK_PS_FILE="$MOCK_DIR/ps_dupsession.txt"
export MOCK_PANE_FILE="$MOCK_DIR/panes_dupsession.txt"
output=$("$PROJECT_DIR/scripts/discover.sh")

if echo "$output" | rg -q "pane1:0.0"; then
    pass "duplicate session: first pane is discovered"
else
    fail "duplicate session: first pane is discovered (got: $output)"
fi

if echo "$output" | rg -q "pane2:1.0"; then
    pass "duplicate session: second pane is discovered"
else
    fail "duplicate session: second pane is discovered (got: $output)"
fi

# Both should reference the same session ID
count=$(echo "$output" | rg -c "aaaa-bbbb" || echo 0)
if [ "$count" -eq 2 ]; then
    pass "duplicate session: both panes reference same session ID"
else
    fail "duplicate session: both panes reference same session ID (count: $count, got: $output)"
fi

# Cleanup extra fixture
rm -f "$FIXTURES_DIR/sessions/12346.json"

# Restore original mocks for remaining tests
export MOCK_PS_FILE="$MOCK_DIR/ps.txt"
export MOCK_PANE_FILE="$MOCK_DIR/panes.txt"

# Test: empty ps output produces no output
echo -n "" >"$MOCK_DIR/ps_empty.txt"
export MOCK_PS_FILE="$MOCK_DIR/ps_empty.txt"
output=$("$PROJECT_DIR/scripts/discover.sh" || true)
if [ -z "$output" ]; then
    pass "empty ps output produces no output"
else
    fail "empty ps output produces no output (got: $output)"
fi

# Test: empty pane output produces no output
export MOCK_PS_FILE="$MOCK_DIR/ps.txt"
echo -n "" >"$MOCK_DIR/panes_empty.txt"
export MOCK_PANE_FILE="$MOCK_DIR/panes_empty.txt"
output=$("$PROJECT_DIR/scripts/discover.sh" || true)
if [ -z "$output" ]; then
    pass "empty pane output produces no output"
else
    fail "empty pane output produces no output (got: $output)"
fi

summary
