#!/usr/bin/env bash
# Tests for search.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

echo "Testing search.sh..."

# Fix popup width so tests are independent of the terminal running them.
export POPUP_COLS=200

# Create discover TSV pointing to fixture JSONL files
DISCOVER_TSV=$(mktemp)
trap 'rm -f "$DISCOVER_TSV"' EXIT

printf 'main:0.0\taaaa-bbbb\t/test/project\t%s\tidle\tfix muffin bug\tfix muffin bug\n' \
    "$FIXTURES_DIR/projects/-test-project/aaaa-bbbb.jsonl" >"$DISCOVER_TSV"
printf 'work:1.0\tcccc-dddd\t/test/other\t%s\tactive\trefactor fleet\trefactor fleet\n' \
    "$FIXTURES_DIR/projects/-test-project/cccc-dddd.jsonl" >>"$DISCOVER_TSV"

# Test: empty query lists all sessions
output=$("$PROJECT_DIR/scripts/search.sh" "" "$DISCOVER_TSV")
if echo "$output" | rg -q "main:0.0"; then
    pass "empty query lists first session"
else
    fail "empty query lists first session (got: $output)"
fi

if echo "$output" | rg -q "work:1.0"; then
    pass "empty query lists second session"
else
    fail "empty query lists second session (got: $output)"
fi

if echo "$output" | rg -q "idle"; then
    pass "empty query shows status"
else
    fail "empty query shows status (got: $output)"
fi

# Test: content search finds matching session
output=$("$PROJECT_DIR/scripts/search.sh" "muffin" "$DISCOVER_TSV")
if echo "$output" | rg -q "main:0.0"; then
    pass "content search finds muffin session"
else
    fail "content search finds muffin session (got: $output)"
fi

# Test: search shows context snippet
if echo "$output" | rg -qi "muffin"; then
    pass "content search shows snippet with query"
else
    fail "content search shows snippet with query (got: $output)"
fi

# Test: search finds in second session
output=$("$PROJECT_DIR/scripts/search.sh" "bicycle" "$DISCOVER_TSV")
if echo "$output" | rg -q "work:1.0"; then
    pass "content search finds bicycle rental session"
else
    fail "content search finds bicycle rental session (got: $output)"
fi

# Test: search doesn't return non-matching sessions
output=$("$PROJECT_DIR/scripts/search.sh" "muffin" "$DISCOVER_TSV")
if echo "$output" | rg -q "work:1.0"; then
    fail "muffin search should not match bicycle rental session"
else
    pass "muffin search only matches relevant session"
fi

# Test: non-matching search returns empty
output=$("$PROJECT_DIR/scripts/search.sh" "zzz_no_match_zzz" "$DISCOVER_TSV")
if [ -z "$output" ]; then
    pass "non-matching search returns empty"
else
    fail "non-matching search returns empty (got: $output)"
fi

# Test: missing discover file returns empty
output=$("$PROJECT_DIR/scripts/search.sh" "test" "/nonexistent/file")
if [ -z "$output" ]; then
    pass "missing discover file returns empty"
else
    fail "missing discover file returns empty (got: $output)"
fi

# Test: case-insensitive search
output=$("$PROJECT_DIR/scripts/search.sh" "MUFFIN" "$DISCOVER_TSV")
if echo "$output" | rg -q "main:0.0"; then
    pass "case-insensitive search works"
else
    fail "case-insensitive search works (got: $output)"
fi

# Test: attachment-only matches are excluded (no empty snippet rows)
ATTACH_TSV=$(mktemp)
SMALL_TSV=$(mktemp)
trap 'rm -f "$DISCOVER_TSV" "$ATTACH_TSV" "$SMALL_TSV"' EXIT
printf 'pop:0.0\teeee-ffff\t/test/zebra\t%s\tidle\t-\tworking on apples\n' \
    "$FIXTURES_DIR/projects/-test-project/eeee-ffff.jsonl" >"$ATTACH_TSV"

output=$("$PROJECT_DIR/scripts/search.sh" "zebra" "$ATTACH_TSV")
if [ -z "$output" ]; then
    pass "attachment-only match is excluded (zebra appears only in attachment metadata)"
else
    fail "attachment-only match is excluded (got: $output)"
fi

# Tests against a small synthetic transcript with multiple matches —
# verify the snippet shown is the *most recent* match (matching preview's first row).
printf 'small:0.0\tgggg-hhhh\t/test/timers\t%s\tidle\t-\ttimer work\n' \
    "$FIXTURES_DIR/projects/-test-project/gggg-hhhh.jsonl" >"$SMALL_TSV"

# Query with multiple matches across user + assistant: most recent is a4
output=$("$PROJECT_DIR/scripts/search.sh" "AcornTimer" "$SMALL_TSV")
if echo "$output" | rg -q "small:0.0"; then
    pass "AcornTimer query matches the small session"
else
    fail "AcornTimer query matches the small session (got: $output)"
fi
if echo "$output" | rg -q "should be migrated"; then
    pass "AcornTimer snippet is from the most recent match (a4 contains 'should be migrated')"
else
    fail "AcornTimer snippet is from the most recent match (got: $output)"
fi

# Query matching tool_result + multiple assistant messages: most recent is a4
output=$("$PROJECT_DIR/scripts/search.sh" "SquirrelTimer" "$SMALL_TSV")
if echo "$output" | rg -q "when touched"; then
    pass "SquirrelTimer snippet is from the most recent match (a4 contains 'when touched')"
else
    fail "SquirrelTimer snippet is from the most recent match (got: $output)"
fi

# Query with a single match: snippet contains the surrounding text
output=$("$PROJECT_DIR/scripts/search.sh" "timing-conventions" "$SMALL_TSV")
if echo "$output" | rg -q "timing-conventions skill"; then
    pass "timing-conventions single match shows its surrounding context"
else
    fail "timing-conventions single match shows its surrounding context (got: $output)"
fi

# Test: fast path skips, fallback recovers the result.
# SEARCH_FAST_LIMIT=0 forces tail -0 to send nothing through jq, which yields
# an empty fast-path result. The fallback path scans every matching line
# and must still find the most recent match.
output=$(SEARCH_FAST_LIMIT=0 "$PROJECT_DIR/scripts/search.sh" "AcornTimer" "$SMALL_TSV")
if echo "$output" | rg -q "should be migrated"; then
    pass "fallback path recovers the most recent match when fast path is empty"
else
    fail "fallback path recovers the most recent match when fast path is empty (got: $output)"
fi

# Tests: context chars scale with popup width.
# Fixture sentence: "I'll invoke the timing-conventions skill since this is about timer usage patterns."
# Right of query: " skill since this is about timer usage patterns." = 48 chars
#
# POPUP_COLS=200: CONTEXT_CHARS=(160-18)/2=71  → all 48 right chars fit → "patterns" visible
# POPUP_COLS=80:  CONTEXT_CHARS=(40-18)/2=11   → " skill sinc" (11) → "skill" visible, "patterns" not
# POPUP_COLS=50:  TEXT_MAX=10 < query(18) → CONTEXT_CHARS=0, no truncation → full query shown

out_wide=$(POPUP_COLS=200 "$PROJECT_DIR/scripts/search.sh" "timing-conventions" "$SMALL_TSV")
out_narrow=$(POPUP_COLS=80 "$PROJECT_DIR/scripts/search.sh" "timing-conventions" "$SMALL_TSV")
out_tiny=$(POPUP_COLS=50 "$PROJECT_DIR/scripts/search.sh" "timing-conventions" "$SMALL_TSV")

if echo "$out_wide" | rg -q "patterns"; then
    pass "wide popup (200): 'patterns' visible — 48-char right context fits in CONTEXT_CHARS=71"
else
    fail "wide popup (200): 'patterns' not visible (got: $out_wide)"
fi

if echo "$out_narrow" | rg -q "skill"; then
    pass "narrow popup (80): 'skill' visible — within 11-char right context"
else
    fail "narrow popup (80): 'skill' not visible (got: $out_narrow)"
fi
if ! echo "$out_narrow" | rg -q "patterns"; then
    pass "narrow popup (80): 'patterns' not visible — beyond 11-char right context"
else
    fail "narrow popup (80): 'patterns' should not appear (got: $out_narrow)"
fi

# POPUP_COLS=50: TEXT_MAX(10) < query(18) → CONTEXT_CHARS=0, no truncation → full query visible
if echo "$out_tiny" | rg -q "timing-conventions"; then
    pass "tiny popup (50, TEXT_MAX < query): full query shown, no truncation"
else
    fail "tiny popup (50): query term missing (got: $out_tiny)"
fi
if ! echo "$out_tiny" | rg -q "patterns"; then
    pass "tiny popup (50): no context shown beyond query"
else
    fail "tiny popup (50): 'patterns' should not appear (got: $out_tiny)"
fi

summary
