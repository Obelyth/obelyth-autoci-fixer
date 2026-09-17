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
#
# The checks run in a fresh worktree of HEAD, not in the working tree the fixer
# left behind. What is committed is what gets pushed, so it is the only thing
# a pass here may vouch for: an untracked helper, an ignored .env, or an edit
# that was never committed would otherwise earn a verified=true for a commit
# that does not contain it.
set -uo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
DIAGNOSIS="${DIAGNOSIS:-}"
VERIFY_LOG="${VERIFY_LOG:-${RUNNER_TEMP}/verify-output.log}"
VERIFY_TREE="${VERIFY_TREE:-${RUNNER_TEMP}/verify-tree}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
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
  # No lockfile: the fresh worktree still needs its dependencies.
  [[ -f package.json ]] && { echo "npm install --ignore-scripts"; return; }
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

# Did a test file run here, was it skipped whole, was it partly skipped, or
# is there no sign of it? Reads the runner's own output - vitest, jest,
# pytest, go and cargo shapes.
SKIP_RE='↓|\([0-9]+ tests? \| [0-9]+ skipped\)|SKIPPED|--- SKIP|\[skipped\]|○ skipped'
FULL_SKIP_RE='\(([0-9]+) tests? \| \1 skipped\)'
RAN_RE='✓|✗|×|❯|PASS([[:space:]]|$)|FAIL([[:space:]]|$)|passed|failed|PASSED|FAILED|--- (PASS|FAIL)|^ok([[:space:]]|$)|\.\.\. ok'
PASS_RE='✓|√|PASS([[:space:]]|$)|PASSED|passed|--- PASS|^ok([[:space:]]|$)|\.\.\. ok'
test_status() {
  local t="$1" log="$2" hits esc
  hits="$(grep -F -- "$t" "$log" || true)"
  [[ -z "$hits" ]] && hits="$(grep -F -- "$(basename "$t")" "$log" || true)"
  [[ -z "$hits" ]] && { echo absent; return; }
  # pytest's per-file progress: a row of nothing but s is a whole-file skip,
  # a row with dots and an s among them is a partial one.
  esc="$(printf '%s' "$t" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  if grep -qE "^${esc}[[:space:]]+s+[[:space:]]*(\[|$)" <<< "$hits"; then echo skipped; return; fi
  if grep -qE "^${esc}[[:space:]]+[.sFxXE]*s[.sFxXE]*[[:space:]]*(\[|$)" <<< "$hits"; then echo partial; return; fi
  if grep -qE "$SKIP_RE" <<< "$hits"; then
    if grep -qE "$FULL_SKIP_RE" <<< "$hits" || ! grep -qE "$RAN_RE" <<< "$hits"; then echo skipped; return; fi
    echo partial; return
  fi
  echo ran
}

# A partly skipped file counts as run only if every case the diagnosis names
# as failing in it is seen passing by name. Without the names, or without a
# verbose reporter that prints them, the skipped part could be exactly the
# failing case - which is the motivating shape - so it is not taken as run.
cases_seen_passing() {  # file, log
  local t="$1" log="$2" n any=false
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    any=true
    grep -Fw -- "$n" "$log" | grep -qE "$PASS_RE" || return 1
  done < <(jq -r --arg f "$t" '.failing_cases[]? | select(.file == $f) | .name' "$DIAGNOSIS" 2>/dev/null)
  $any
}

# --- A fresh worktree of HEAD, where the checks run ----------------------------
ORIGIN_DIR="$(pwd)"
HEAD_SHA="$(git rev-parse HEAD)"
cleanup() { cd "$ORIGIN_DIR" || return; git worktree remove --force "$VERIFY_TREE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [[ -e "$VERIFY_TREE" ]]; then git worktree remove --force "$VERIFY_TREE" >/dev/null 2>&1 || rm -rf "$VERIFY_TREE"; fi
if ! git worktree add --detach -q "$VERIFY_TREE" "$HEAD_SHA" >/dev/null 2>&1; then
  echo "::error::Could not create a clean worktree of $HEAD_SHA to verify in." >&2
  echo "verified=false" >> "$GITHUB_OUTPUT"
  echo "could_not_run=" >> "$GITHUB_OUTPUT"
  exit 1
fi
cd "$VERIFY_TREE" || exit 1

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
    if git checkout -q --detach "$BASE_SHA" 2>/dev/null; then
      eval "$c" >/dev/null 2>&1 || baseline_failed=true
      git checkout -q --detach "$HEAD_SHA" 2>/dev/null || true
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
      partial) cases_seen_passing "$t" "$CLEAN" || COULD_NOT_RUN+=("$t (partly skipped here, and the failing case was not seen to pass)") ;;
      skipped) COULD_NOT_RUN+=("$t (skipped here)") ;;
      absent)  COULD_NOT_RUN+=("$t (did not run here)") ;;
      *) ;;
    esac
  done < <(jq -r '.failing_tests[]?' "$DIAGNOSIS" 2>/dev/null)
fi

if (( ${#COULD_NOT_RUN[@]} )); then
  LIST="$(printf '%s; ' "${COULD_NOT_RUN[@]}" | sed 's/; $//')"
  echo "::error::The checks pass here, but the test that was failing could not be run: $LIST. A green run that never exercised the failing test proves nothing, so nothing is pushed." >&2
  {
    echo "## Verification"
    echo
    echo "Every check command passed in the runner - but the failing test could not be run here:"
    echo
    for t in "${COULD_NOT_RUN[@]}"; do echo "- \`$t\`"; done
    echo
    echo "Most often the test needs something this job cannot provide that the repository's"
    echo "own CI does: a service, a scoped token, or a sibling checkout done in another job."
    echo "A file that was only partly skipped counts as run only when the failing case is"
    echo "seen passing by name, which needs a reporter that prints case names (\`test_command\`)."
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
  echo "All checks pass in a clean worktree of \`${HEAD_SHA:0:8}\`:"
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
