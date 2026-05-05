#!/usr/bin/env bash
# Tests for preview.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

echo "Testing preview.sh..."

# Create discover TSV
DISCOVER_TSV=$(mktemp)
trap 'rm -f "$DISCOVER_TSV"' EXIT

printf 'main:0.0\taaaa-bbbb\t/test/project\t%s\tidle\tfix muffin bug\tfix muffin bug\n' \
	"$FIXTURES_DIR/projects/-test-project/aaaa-bbbb.jsonl" >"$DISCOVER_TSV"
printf 'work:1.0\tcccc-dddd\t/test/other\t%s\tactive\trefactor fleet\trefactor fleet\n' \
	"$FIXTURES_DIR/projects/-test-project/cccc-dddd.jsonl" >>"$DISCOVER_TSV"

# Test: empty query shows last prompt
output=$("$PROJECT_DIR/scripts/preview.sh" "main:0.0" "" "$DISCOVER_TSV")
if echo "$output" | rg -q "thanks, looks good"; then
	pass "empty query shows last prompt"
else
	fail "empty query shows last prompt (got: $output)"
fi

# Test: query shows matching messages
output=$("$PROJECT_DIR/scripts/preview.sh" "main:0.0" "muffin" "$DISCOVER_TSV")
if echo "$output" | rg -qi "muffin"; then
	pass "query shows matching muffin messages"
else
	fail "query shows matching muffin messages (got: $output)"
fi

# Test: shows user messages
if echo "$output" | rg -q "\[user\]"; then
	pass "shows user message labels"
else
	fail "shows user message labels (got: $output)"
fi

# Test: shows assistant messages
if echo "$output" | rg -q "\[ ai \]"; then
	pass "shows assistant message labels"
else
	# Also try without space padding
	if echo "$output" | rg -q "\[ai\]"; then
		pass "shows assistant message labels (ai)"
	else
		fail "shows assistant message labels (got: $output)"
	fi
fi

# Test: shows timestamps
if echo "$output" | rg -q "[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}"; then
	pass "shows formatted timestamps"
else
	fail "shows formatted timestamps (got: $output)"
fi

# Test: non-matching query in session
output=$("$PROJECT_DIR/scripts/preview.sh" "main:0.0" "zzz_no_match_zzz" "$DISCOVER_TSV")
if echo "$output" | rg -q "no matches"; then
	pass "non-matching query shows no matches"
else
	# May just be empty
	if [ -z "$output" ]; then
		pass "non-matching query returns empty"
	else
		fail "non-matching query (got: $output)"
	fi
fi

# Test: unknown pane returns gracefully
output=$("$PROJECT_DIR/scripts/preview.sh" "unknown:9.9" "test" "$DISCOVER_TSV")
if echo "$output" | rg -q "no transcript"; then
	pass "unknown pane shows no transcript message"
else
	if [ -z "$output" ]; then
		pass "unknown pane returns empty"
	else
		fail "unknown pane (got: $output)"
	fi
fi

# Test: missing discover file
output=$("$PROJECT_DIR/scripts/preview.sh" "main:0.0" "test" "/nonexistent" 2>&1 || true)
if [ -z "$output" ]; then
	pass "missing discover file returns empty"
else
	fail "missing discover file returns empty (got: $output)"
fi

# Test: second session works
output=$("$PROJECT_DIR/scripts/preview.sh" "work:1.0" "timeout" "$DISCOVER_TSV")
if echo "$output" | rg -qi "timeout"; then
	pass "second session preview works"
else
	fail "second session preview works (got: $output)"
fi

# Test: empty query on second session shows its last prompt
output=$("$PROJECT_DIR/scripts/preview.sh" "work:1.0" "" "$DISCOVER_TSV")
if echo "$output" | rg -q "run the tests"; then
	pass "second session shows its own last prompt"
else
	fail "second session shows its own last prompt (got: $output)"
fi

# Box content tests — verify multiple matches are listed, ordered most-recent-first,
# and that the first row matches what search.sh shows in the list snippet.
output=$("$PROJECT_DIR/scripts/preview.sh" "main:0.0" "muffin" "$DISCOVER_TSV")

# Strip ANSI color codes for stable assertions
plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')

# Test: multiple matches shown (the muffin fixture has many user+assistant matches)
match_count=$(printf '%s\n' "$plain" | rg -c "muffin" || echo 0)
if [ "$match_count" -ge 3 ]; then
	pass "preview shows multiple matching rows (got $match_count)"
else
	fail "preview shows multiple matching rows (got $match_count: $plain)"
fi

# Test: rows are ordered with most recent first.
# In the fixture, a9 (timestamp 10:02:20) is the latest message containing "muffin"
# and contains "Fixed.", while u1 (10:00:01) contains "fix the" — first row must be a9.
first_row=$(printf '%s\n' "$plain" | head -1)
if printf '%s' "$first_row" | rg -q "Fixed\."; then
	pass "preview rows are ordered most-recent-first (top row is from a9)"
else
	fail "preview rows are ordered most-recent-first (top row: $first_row)"
fi

# Test: first preview row matches the snippet search.sh shows in the list line.
search_out=$("$PROJECT_DIR/scripts/search.sh" "muffin" "$DISCOVER_TSV")
# The list snippet is everything after the cwd column (truncated to 80 chars).
# Both should reference the same most-recent message ("Fixed. The muffin baking bug...").
if printf '%s' "$search_out" | rg -q "Fixed\. The muffin"; then
	pass "search list snippet points to the same message preview's first row shows"
else
	fail "search list/preview snippets disagree (search: $search_out / preview top: $first_row)"
fi

summary
