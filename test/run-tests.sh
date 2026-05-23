#!/usr/bin/env bash
# Run all tmux-claude-finder tests

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()

for test_file in "$TEST_DIR"/test-*.sh; do
    [ -f "$test_file" ] || continue
    echo ""
    echo "=== $(basename "$test_file") ==="
    if output=$(bash "$test_file" 2>&1); then
        echo "$output"
    else
        echo "$output"
        FAILED_SUITES+=("$(basename "$test_file")")
    fi

    pass_count=$(echo "$output" | rg -c "PASS:" 2>/dev/null || echo 0)
    fail_count=$(echo "$output" | rg -c "FAIL:" 2>/dev/null || echo 0)
    TOTAL_PASS=$((TOTAL_PASS + pass_count))
    TOTAL_FAIL=$((TOTAL_FAIL + fail_count))
done

echo ""
echo "=============================="
echo "Total: $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo "Failed suites: ${FAILED_SUITES[*]}"
    exit 1
fi
