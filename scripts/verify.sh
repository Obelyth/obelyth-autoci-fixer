#!/usr/bin/env bash
# Independently re-runs the repo's own checks inside the runner. Claude is asked
# to do this too; this step is here so the push is gated on a result the workflow
# saw for itself rather than on a claim.
#
# "Saw for itself" includes the tests the diagnosis said were failing. If the
# suite passes here but one of those files was skipped or never ran, the pass
# proves nothing about the failure, and the run stops instead of pushing. That
# is the gap the motivating run fell through: the failing suite skips itself
# without a private checkout this runner does not have, so the suite was green
# and the fix was never actually tested.
set -uo pipefail

DIAGNOSIS="${DIAGNOSIS:-}"
VERIFY_LOG="${VERIFY_LOG:-${RUNNER_TEMP}/verify-output.log}"
: > "$VERIFY_LOG"

detect_setup() {
  [[ -n "${SETUP_COMMAND:-}" ]] && { echo "$SETUP_COMMAND"; return; }
  [[ -f bun.lockb || -f bun.lock ]] && { echo "bun install --frozen-lockfile"; return; }
  [[ -f pnpm-lock.yaml ]] && { echo "pnpm install --frozen-lockfile"; return; }
  [[ -f yarn.lock ]] && { echo "yarn install --frozen-lockfile"; return; }
  [[ -f package-lock.json ]] && { echo "npm ci --ignore-scripts"; return; }
  [[ -f uv.lock ]] && { echo "uv sync --frozen"; return; }
  [[ -f poetry.lock ]] && { echo "poetry install"; return; }
  [[ -f requirements.txt ]] && { echo "pip install -r requirements.txt"; return; }
  [[ -f go.mod ]] && { echo "go mod download"; return; }
  [[ -f Cargo.toml ]] && { echo "cargo fetch"; return; }
  echo ""
}

detect_test() {
  [[ -n "${TEST_COMMAND:-}" ]] && { echo "$TEST_COMMAND"; return; }
  if [[ -f package.json ]]; then
    # Run the same gates the CI workflow runs, in the same order, skipping any
    # script this repo does not define.
    cmds=()
    for s in lint typecheck boundaries test build; do
      if jq -e --arg s "$s" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
        cmds+=("npm run $s --if-present")
      fi
    done
    (( ${#cmds[@]} )) && { printf '%s\n' "${cmds[@]}"; return; }
  fi
  [[ -f pyproject.toml || -d tests ]] && { echo "python -m pytest -q"; return; }
  [[ -f go.mod ]] && { echo "go test ./..."; return; }
  [[ -f Cargo.toml ]] && { echo "cargo test"; return; }
  [[ -f Makefile ]] && grep -qE '^test:' Makefile && { echo "make test"; return; }
  echo ""
}

# Did a test file run here, or was it skipped, or is there no sign of it?
# Reads the runner's own output - vitest, jest, pytest, go and cargo shapes.
test_status() {
  local t="$1" log="$2" hits esc
  hits="$(grep -F -- "$t" "$log" || true)"
  [[ -z "$hits" ]] && hits="$(grep -F -- "$(basename "$t")" "$log" || true)"
  [[ -z "$hits" ]] && { echo absent; return; }
  # Every mention is a skip and none is a pass or a failure.
  if grep -qE '↓|\(([0-9]+) tests? \| \1 skipped\)|SKIPPED|--- SKIP|\[skipped\]|○ skipped' <<< "$hits" \
     && ! grep -qE '✓|✗|×|❯|PASS([[:space:]]|$)|FAIL([[:space:]]|$)|passed|failed|PASSED|FAILED|--- (PASS|FAIL)|^ok([[:space:]]|$)|\.\.\. ok' <<< "$hits"; then
    echo skipped; return
  fi
  # pytest's per-file progress: a row of nothing but s.
  esc="$(printf '%s' "$t" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  if grep -qE "^${esc}[[:space:]]+s+[[:space:]]*(\[|$)" <<< "$hits"; then
    echo skipped; return
  fi
  echo ran
}

SETUP="$(detect_setup)"
mapfile -t CHECKS < <(detect_test)

if (( ${#CHECKS[@]} == 0 )); then
  echo "::warning::Could not work out how to run this repo's checks, so the fix was not independently verified here."
  echo "summary=not verified locally (no check command found)" >> "$GITHUB_OUTPUT"
  echo "verified=false" >> "$GITHUB_OUTPUT"
  echo "could_not_run=" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [[ -n "$SETUP" ]]; then
  echo "::group::$SETUP"
  eval "$SETUP" || { echo "::error::Dependency install failed: $SETUP"; exit 1; }
  echo "::endgroup::"
fi

PASSED=()
for c in "${CHECKS[@]}"; do
  echo "::group::$c"
  if eval "$c" 2>&1 | tee -a "$VERIFY_LOG"; then
    PASSED+=("$c")
    echo "::endgroup::"
  else
    echo "::endgroup::"

    # Was this already failing before the fix?
    #
    # A repo's own CI can provide things this job cannot. cortex is the case that
    # taught us: several of its suites need a sibling checkout of a private repo,
    # which its CI does in a separate job with a scoped token. Running the whole
    # command here fails those tests no matter how good the fix is, and blaming
    # the fix for it is simply wrong - it reports a false negative and throws away
    # correct work.
    #
    # So on failure, and only on failure, re-run the same command at the commit we
    # started from. If it failed there too, the cause predates the fix.
    echo "::group::checking whether \`$c\` already failed before the fix"
    baseline_failed=false
    if git stash push -q --include-untracked -m ci-autofix-verify 2>/dev/null; then
      if git checkout -q "$BASE_SHA" -- . 2>/dev/null; then
        eval "$c" >/dev/null 2>&1 || baseline_failed=true
        git checkout -q HEAD -- . 2>/dev/null || true
      fi
      git stash pop -q 2>/dev/null || true
    fi
    echo "::endgroup::"

    if $baseline_failed; then
      echo "::warning::\`$c\` also fails at ${BASE_SHA:0:8}, before the fix. The cause predates this change and is not something the fix broke."
      {
        echo "## Verification"
        echo
        echo "\`$c\` fails — but it also fails at \`${BASE_SHA:0:8}\`, before the fix."
        echo
        echo "So this is not the fix's doing. Most often it means the suite needs"
        echo "something this job cannot provide that the repository's own CI does:"
        echo "a service, a scoped token, or a sibling checkout done in another job."
        echo
        echo "Nothing was pushed, because green was never demonstrated here."
      } >> "$GITHUB_STEP_SUMMARY"
      echo "verified=false" >> "$GITHUB_OUTPUT"
      echo "preexisting=true" >> "$GITHUB_OUTPUT"
      echo "could_not_run=" >> "$GITHUB_OUTPUT"
      exit 1
    fi

    echo "::error::Still failing after the fix: $c"
    {
      echo "## Verification"
      echo
      echo "\`$c\` still fails, and it passed at \`${BASE_SHA:0:8}\`. Nothing was pushed."
    } >> "$GITHUB_STEP_SUMMARY"
    echo "verified=false" >> "$GITHUB_OUTPUT"
    echo "could_not_run=" >> "$GITHUB_OUTPUT"
    exit 1
  fi
done

# --- The suite passed. Did the tests that were failing actually run? ----------
COULD_NOT_RUN=()
if [[ -n "$DIAGNOSIS" && -f "$DIAGNOSIS" ]]; then
  CLEAN="${RUNNER_TEMP}/verify-clean.log"
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$VERIFY_LOG" > "$CLEAN"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    case "$(test_status "$t" "$CLEAN")" in
      ran) ;;
      skipped) COULD_NOT_RUN+=("$t (skipped here)") ;;
      absent)  COULD_NOT_RUN+=("$t (did not run here)") ;;
    esac
  done < <(jq -r '.failing_tests[]?' "$DIAGNOSIS" 2>/dev/null)
fi

if (( ${#COULD_NOT_RUN[@]} )); then
  LIST="$(printf '%s; ' "${COULD_NOT_RUN[@]}" | sed 's/; $//')"
  echo "::error::The checks pass here, but the test that was failing could not be run: $LIST. A green run that never exercised the failing test proves nothing, so nothing is pushed."
  {
    echo "## Verification"
    echo
    echo "Every check command passed in the runner - but the failing test could not be run here:"
    echo
    for t in "${COULD_NOT_RUN[@]}"; do echo "- \`$t\`"; done
    echo
    echo "Most often the test needs something this job cannot provide that the repository's"
    echo "own CI does: a service, a scoped token, or a sibling checkout done in another job."
    echo "A pass that never ran the failing test is not proof, so nothing was pushed."
  } >> "$GITHUB_STEP_SUMMARY"
  echo "verified=false" >> "$GITHUB_OUTPUT"
  echo "could_not_run=$LIST" >> "$GITHUB_OUTPUT"
  exit 1
fi

SUMMARY="$(printf '%s; ' "${PASSED[@]}" | sed 's/; $//')"
{
  echo "## Verification"
  echo
  echo "All checks pass in the runner:"
  echo
  for c in "${PASSED[@]}"; do echo "- \`$c\`"; done
  if [[ -n "$DIAGNOSIS" && -f "$DIAGNOSIS" ]] && jq -e '.failing_tests | length > 0' "$DIAGNOSIS" >/dev/null 2>&1; then
    echo
    echo "The test that was failing ran here and passed: $(jq -r '.failing_tests | join(", ")' "$DIAGNOSIS")."
  fi
} >> "$GITHUB_STEP_SUMMARY"

echo "summary=$SUMMARY" >> "$GITHUB_OUTPUT"
echo "verified=true" >> "$GITHUB_OUTPUT"
echo "could_not_run=" >> "$GITHUB_OUTPUT"
