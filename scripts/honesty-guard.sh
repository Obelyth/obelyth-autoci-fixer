#!/usr/bin/env bash
# Inspects the change Claude just made and fails the job if the green tick was
# bought rather than earned. There is deliberately no override: if a fix really
# does need a test removed or a gate relaxed, a person does that, not this robot.
#
# Since the diagnosis step exists, this also holds the fix to the box the
# diagnosis drew: every changed path has to be in allowed_paths, and the whole
# change has to fit under the size caps. The deny list the fixer ran under is
# the polite version of the same rule; this is the one that counts - which is
# why the workflow hands it a diagnosis re-materialised from the triage job's
# output, and runs it only after checking the toolkit itself is untouched.
set -uo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
MAX_CHANGED_FILES="${MAX_CHANGED_FILES:-5}"
MAX_CHANGED_LINES="${MAX_CHANGED_LINES:-150}"

FAILURES=()
note() { FAILURES+=("$1"); }

DIFF_RANGE="${BASE_SHA}..HEAD"

# --- 0. There has to be a commit, and it has to be additional history. --------
if [[ "$(git rev-parse HEAD)" == "$BASE_SHA" ]]; then
  echo "No commit was made. Nothing to check, and nothing to push."
  echo "clean=false" >> "$GITHUB_OUTPUT"
  echo "verdict=no-commit" >> "$GITHUB_OUTPUT"
  exit 1
fi

if ! git merge-base --is-ancestor "$BASE_SHA" HEAD; then
  note "History was rewritten. The starting commit \`${BASE_SHA:0:8}\` is no longer an ancestor of HEAD, which means a rebase, reset or amend dropped it. Fixes must only ever add commits."
fi

# An empty commit would push nothing, re-run the identical CI, fail in the
# identical way, and spend one of the three attempts doing it.
if git diff --quiet "$BASE_SHA" HEAD; then
  echo "The commit changes no files. Pushing it would re-run the same CI against the same code."
  echo "clean=false" >> "$GITHUB_OUTPUT"
  echo "verdict=empty-diff" >> "$GITHUB_OUTPUT"
  exit 1
fi

ADDED="$(git diff "$DIFF_RANGE" --unified=0 | grep -E '^\+' | grep -v '^+++' || true)"

# The changed paths, read NUL-separated and unquoted so that a name with a
# space or an accent in it is one path, not two. A rename counts both its old
# and its new name as changed.
STATUSES=(); PATHS=()
while IFS= read -r -d '' status; do
  IFS= read -r -d '' path || break
  case "$status" in
    R*|C*)
      IFS= read -r -d '' newpath || break
      STATUSES+=("$status" "$status"); PATHS+=("$path" "$newpath") ;;
    *)
      STATUSES+=("$status"); PATHS+=("$path") ;;
  esac
done < <(git -c core.quotePath=false diff --name-status -z "$DIFF_RANGE")
all_paths()     { (( ${#PATHS[@]} )) && printf '%s\n' "${PATHS[@]}"; return 0; }
deleted_paths() { local i; for i in "${!PATHS[@]}"; do [[ "${STATUSES[i]}" == D* ]] && printf '%s\n' "${PATHS[i]}"; done; return 0; }

# --- 1. Deleted test files. ---------------------------------------------------
DELETED_TESTS="$(deleted_paths | grep -Ei '(\.test\.|\.spec\.|(^|/)test_|_test\.|Tests?\.swift$|(^|/)tests?/)' || true)"
if [[ -n "$DELETED_TESTS" ]]; then
  note "Test files were deleted:
$(echo "$DELETED_TESTS" | sed 's/^/    - /')"
fi

# --- 2. Skip and ignore markers added. ----------------------------------------
SKIPS="$(echo "$ADDED" | grep -Ein \
  '(it|test|describe|context|suite)\.(skip|todo|failing)\b|\bxit\s*\(|\bxdescribe\s*\(|\bxtest\s*\(|@pytest\.mark\.(skip|xfail)|@unittest\.skip|\bt\.Skip\s*\(|#\[ignore\]|@Ignore\b|\.skip\s*\(|pending\s*\(' || true)"
if [[ -n "$SKIPS" ]]; then
  note "Tests were skipped or marked as expected failures:
$(echo "$SKIPS" | head -20 | sed 's/^/    /')"
fi

# --- 3. CI gates relaxed. -----------------------------------------------------
CI_TOUCHED="$(all_paths | grep -E '^\.github/workflows/' || true)"
if [[ -n "$CI_TOUCHED" ]]; then
  CI_ADDED="$(git diff "$DIFF_RANGE" --unified=0 -- .github/workflows/ | grep -E '^\+' | grep -v '^+++' || true)"
  CI_REMOVED="$(git diff "$DIFF_RANGE" --unified=0 -- .github/workflows/ | grep -E '^-' | grep -v '^---' || true)"

  if echo "$CI_ADDED" | grep -Eiq 'continue-on-error:\s*true|if:\s*false|\|\|\s*true|--no-verify|--force|fail-fast:\s*false\s*#\s*disabled'; then
    note "A CI workflow was changed in a way that stops a failure from failing the build:
$(echo "$CI_ADDED" | grep -Ein 'continue-on-error:\s*true|if:\s*false|\|\|\s*true|--no-verify|--force' | head -10 | sed 's/^/    /')"
  fi
  # A removed `run:` line in CI means a check was taken out entirely.
  if echo "$CI_REMOVED" | grep -Eq '^\-\s*(- )?run:'; then
    note "A step was removed from a CI workflow. Deleting the check that caught the problem is not fixing the problem:
$(echo "$CI_REMOVED" | grep -E '^\-\s*(- )?run:' | head -10 | sed 's/^/    /')"
  fi
fi

# --- 4. Check commands hollowed out in the package manifest. ------------------
MANIFEST_ADDED="$(git diff "$DIFF_RANGE" --unified=0 -- package.json Makefile pyproject.toml \
  2>/dev/null | grep -E '^\+' | grep -v '^+++' || true)"
if echo "$MANIFEST_ADDED" | grep -Eq '"(test|lint|typecheck|build|boundaries|check)[^"]*"\s*:\s*"(true|echo[^"]*|exit 0)"'; then
  note "A check script was replaced with a command that always succeeds:
$(echo "$MANIFEST_ADDED" | grep -E '"(test|lint|typecheck|build|boundaries|check)[^"]*"\s*:\s*"(true|echo|exit 0)' | head -10 | sed 's/^/    /')"
fi

# --- 5. Local hooks disabled. -------------------------------------------------
HOOK_FILES="$(all_paths | grep -Ei 'lefthook|husky|pre-commit-config|\.githooks/' || true)"
if [[ -n "$HOOK_FILES" ]]; then
  note "Git hook configuration was modified ($(echo "$HOOK_FILES" | tr '\n' ' ')). Hooks are a gate, so changing them is a human decision."
fi

# --- 6. Bypass flags introduced anywhere. ------------------------------------
BYPASS="$(echo "$ADDED" | grep -En -- '--no-verify|git push .*(--force|-f)\b|--admin\b|SKIP=|HUSKY=0|LEFTHOOK=0' || true)"
if [[ -n "$BYPASS" ]]; then
  note "A verification bypass flag was introduced:
$(echo "$BYPASS" | head -10 | sed 's/^/    /')"
fi

# --- 7. The toolkit must not edit itself. ------------------------------------
if all_paths | grep -q '^\.ci-autofix/'; then
  note "The auto-fix toolkit itself was modified. It is checked out read-only and must never appear in a fix."
fi

# The same thing by name, for the case where the repo being fixed IS the toolkit.
# install.sh refuses to install a caller there, but a fork or a hand-written
# caller would not know that, and a fixer that can edit its own rules has none.
SELF="$(all_paths | grep -E '(honesty-guard\.sh|guard_test\.sh|PLAYBOOK\.md|fingerprint\.sh)$' || true)"
if [[ -n "$SELF" ]]; then
  note "The fix changes the rules that judge it:
$(echo "$SELF" | sed 's/^/    - /')"
fi

# --- 8. Test coverage must not shrink. ---------------------------------------
OUT="${RUNNER_TEMP}/fingerprint-after.json" bash "$(dirname "$0")/fingerprint.sh" > /dev/null
before_cases=$(jq -r '.test_cases' "$FINGERPRINT_BEFORE")
after_cases=$(jq -r '.test_cases' "${RUNNER_TEMP}/fingerprint-after.json")
before_asserts=$(jq -r '.assertions' "$FINGERPRINT_BEFORE")
after_asserts=$(jq -r '.assertions' "${RUNNER_TEMP}/fingerprint-after.json")

if (( after_cases < before_cases )); then
  note "The number of test cases fell from $before_cases to $after_cases. Fewer tests is not a passing suite."
fi
if (( after_asserts < before_asserts )); then
  note "The number of assertions fell from $before_asserts to $after_asserts. Removing the check that failed is not a fix."
fi

# --- 9. Every changed path must be inside the diagnosed scope. ----------------
# allowed_paths is what the diagnosis implicated: the source this branch
# changed, or the failing test this branch changed - never a test the branch
# did not touch. No diagnosis means no scope, and no scope means no fix.
CHANGED_PATHS="$(all_paths | sort -u)"
if [[ -n "${DIAGNOSIS:-}" && -f "$DIAGNOSIS" ]]; then
  ALLOWED_PATHS="$(jq -r '.allowed_paths[]?' "$DIAGNOSIS" 2>/dev/null | sort -u)"
  OUT_OF_SCOPE="$(comm -23 <(echo "$CHANGED_PATHS") <(echo "$ALLOWED_PATHS") | grep -v '^$' || true)"
  if [[ -n "$OUT_OF_SCOPE" ]]; then
    note "Files outside the diagnosed scope were changed. The diagnosis implicated only: $(echo "$ALLOWED_PATHS" | grep -v '^$' | paste -sd' ' || true). Out of scope:
$(echo "$OUT_OF_SCOPE" | sed 's/^/    - /')"
  fi
else
  note "No diagnosis was supplied (DIAGNOSIS is unset or missing), so there is no scope to hold the change to."
fi

# --- 10. The change must be small enough to review. --------------------------
# A fix for one failing check is a few lines in a few files. Anything bigger is
# either the wrong fix or several fixes, and either way a person should see it.
# Binary content has no line count to cap and no diff to read, so it is out.
n_files="$(echo "$CHANGED_PATHS" | grep -cv '^$' || true)"
NUMSTAT="$(git -c core.quotePath=false diff --numstat "$DIFF_RANGE")"
n_lines="$(awk -F'\t' '{ a += ($1 == "-" ? 0 : $1); d += ($2 == "-" ? 0 : $2) } END { print a + d + 0 }' <<< "$NUMSTAT")"
BINARY="$(awk -F'\t' '$1 == "-" || $2 == "-" { print $3 }' <<< "$NUMSTAT")"
if [[ -n "$BINARY" ]]; then
  note "Binary content was added or changed. A fix is text a person can read; a blob is neither reviewable nor countable against the size cap:
$(echo "$BINARY" | sed 's/^/    - /')"
fi
if (( n_files > MAX_CHANGED_FILES )); then
  note "The fix changes $n_files files; the cap is $MAX_CHANGED_FILES. A fix that wide needs a person to read it."
fi
if (( n_lines > MAX_CHANGED_LINES )); then
  note "The fix changes $n_lines lines; the cap is $MAX_CHANGED_LINES. A fix that long needs a person to read it."
fi

# --- Verdict ------------------------------------------------------------------
{
  echo "## Honesty check"
  echo
  echo "Comparing \`${BASE_SHA:0:8}\` with the fix commit."
  echo
  echo "| Measure | Before | After |"
  echo "|---|---|---|"
  echo "| Test cases | $before_cases | $after_cases |"
  echo "| Assertions | $before_asserts | $after_asserts |"
  echo "| Files changed | - | $n_files (cap $MAX_CHANGED_FILES) |"
  echo "| Lines changed | - | $n_lines (cap $MAX_CHANGED_LINES) |"
  echo
} >> "$GITHUB_STEP_SUMMARY"

if (( ${#FAILURES[@]} > 0 )); then
  {
    echo "**Blocked.** The change would have made CI pass without fixing the cause:"
    echo
    for f in "${FAILURES[@]}"; do echo "- $f"; done
    echo
    echo "Nothing was pushed. This needs a person."
  } >> "$GITHUB_STEP_SUMMARY"

  echo "::error::Honesty check failed - the fix weakens the tests or the CI gates."
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  echo "clean=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

echo "**Passed.** The fix stays inside the diagnosed scope and changes the code under test, not the tests." >> "$GITHUB_STEP_SUMMARY"
echo "Honesty check passed."
echo "clean=true" >> "$GITHUB_OUTPUT"
echo "files_changed=$n_files" >> "$GITHUB_OUTPUT"
echo "lines_changed=$n_lines" >> "$GITHUB_OUTPUT"
