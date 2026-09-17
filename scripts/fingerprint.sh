#!/usr/bin/env bash
# Counts the tests and assertions in the tree so the honesty guard can tell
# afterwards whether the "fix" quietly removed any of them.
set -euo pipefail

count() { grep -rEIno "$1" --include="$2" . 2>/dev/null | wc -l | tr -d ' '; }

TEST_GLOBS=('*.test.*' '*.spec.*' 'test_*.py' '*_test.py' '*_test.go' '*_test.rb' '*Tests.swift')

test_files=0
for g in "${TEST_GLOBS[@]}"; do
  n=$(find . -path ./node_modules -prune -o -path ./.git -prune -o -path ./.ci-autofix -prune -o -name "$g" -type f -print 2>/dev/null | wc -l)
  test_files=$((test_files + n))
done

# Test declarations across the ecosystems these repos actually use. A tree with
# none is a count of zero, not a failed pipeline: grep exits 1 on no match and
# pipefail would otherwise turn that into no fingerprint at all.
cases=$(grep -rEIn --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.ci-autofix \
  "(^|[^a-zA-Z0-9_])(it|test|describe)\s*\(|^\s*def test_|^\s*func Test[A-Z]|^\s*#\[test\]|@Test\b" . 2>/dev/null | wc -l | tr -d ' ' || true)

asserts=$(grep -rEIn --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.ci-autofix \
  "expect\s*\(|assert[A-Za-z]*\s*\(|\bassert\b|XCTAssert" . 2>/dev/null | wc -l | tr -d ' ' || true)

printf '{"test_files":%s,"test_cases":%s,"assertions":%s}\n' \
  "$test_files" "$cases" "$asserts" | tee "$OUT"
