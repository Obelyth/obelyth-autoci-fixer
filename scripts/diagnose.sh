#!/usr/bin/env bash
# Works out what actually failed, and whether this branch can be blamed for it,
# before any model is run. The answer is written to diagnosis.json and bounds
# everything downstream: the deny list the fixer runs under, the paths the
# honesty guard accepts, and the tests that verification insists on having seen
# run with its own eyes.
#
# Four classes come out:
#   code      a source file this branch changed is implicated   -> fix the code
#   test      only a test this branch changed is implicated     -> fix that test
#   env-data  nothing this branch changed is implicated, and the failing job
#             reads something this checkout does not have        -> stop
#   unlinked  nothing this branch changed is implicated, and no environment
#             signal explains it either                           -> stop
#
# Stopping is a result, not a failure. The run that rewrote three test files
# for a failure caused by data in a private checkout would have stopped here,
# before it spent a single model turn.
#
# Inputs (environment):
#   RUN_JSON       run metadata with .path and .jobs[] (scripts/collect-evidence.sh)
#   RAW_LOG        the failed-step log (same script)
#   REPO           owner/name of the repository being fixed
#   BASE_REF       the branch this one is measured against (PR base, or default)
#   WORKFLOW_FILE  optional; overrides the workflow path recorded in RUN_JSON
#   DIAGNOSIS_OUT  where to write the JSON (default .ci-autofix/diagnosis.json)
set -uo pipefail

RUN_JSON="${RUN_JSON:-${RUNNER_TEMP}/run.json}"
RAW_LOG="${RAW_LOG:-${RUNNER_TEMP}/raw.log}"
OUT="${DIAGNOSIS_OUT:-.ci-autofix/diagnosis.json}"
REPO="${REPO:-}"
BASE_REF="${BASE_REF:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

WORK="${RUNNER_TEMP}/diagnose"
mkdir -p "$WORK" "$(dirname "$OUT")"

# What counts as a test file. Kept in step with fingerprint.sh and the guard.
TEST_RE='(^|/)(tests?|__tests__|specs?|e2e|integration)/|\.(test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]+\.py$|_(test|spec)\.(py|go|rb|ts|tsx|js|jsx|mjs|cjs|rs|swift|kt|java|ex|exs)$|Tests?\.swift$'

# A path-looking token with a source or data extension.
PATH_RE='(\.{0,2}/)?([]A-Za-z0-9_@.[-]+/)*[]A-Za-z0-9_@[-][]A-Za-z0-9_@.[-]*\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|py|go|rs|rb|swift|kt|kts|java|scala|ex|exs|cs|php|c|cc|cpp|h|hpp|m|mm|sql|sh|md|json|ya?ml|toml|cfg|ini|txt|csv)'

# Lines worth pulling paths out of: a failure, or a file:line reference.
INTEREST_RE='FAIL|ERROR|Error|error|panicked|Assertion|assert|Traceback|Exception|Expected|expected|×|✗|✘|❯|##\[error\]|:[0-9]+(:[0-9]+)?([^0-9]|$)|\([0-9]+,[0-9]+\)|", line [0-9]+'
# Lines that report a pass, which are never evidence of a failure even when
# the test's own name happens to contain the word "error".
PASS_LINE_RE='^[[:space:]]*(✓|√|PASS([[:space:]]|$)|ok([[:space:]]|$)|passed|PASSED|\[ *OK *\])'
# Directories whose contents are never the cause and never "missing".
NOISE_RE='(^|/)(node_modules|\.git|\.pnpm|\.yarn|\.venv|venv|site-packages|__pycache__|dist|build|out|coverage|target|\.next|\.cache|\.turbo|vendor|\.ci-autofix)/|^(internal|node|deps|usr|etc|opt|proc|tmp|home|lib64|snap)/'

is_test() { [[ "$1" =~ $TEST_RE ]]; }

# Set helpers over sorted, one-per-line files.
sorted() { grep -v '^$' "$1" 2>/dev/null | sort -u; }
inter()  { comm -12 <(sorted "$1") <(sorted "$2"); }
minus()  { comm -23 <(sorted "$1") <(sorted "$2"); }
lines()  { grep -cv '^$' "$1" 2>/dev/null || true; }
joined() { sorted "$1" | paste -sd' ' | sed 's/ *$//'; }
as_json_array() { if [[ -s "$1" ]]; then sorted "$1" | jq -R . | jq -sc .; else echo '[]'; fi; }

# --- 1. Which jobs and steps failed --------------------------------------------
FAILED_JOBS='[]'
WORKFLOW_PATH="${WORKFLOW_FILE:-}"
if [[ -f "$RUN_JSON" ]]; then
  [[ -z "$WORKFLOW_PATH" ]] && WORKFLOW_PATH="$(jq -r '.path // empty' "$RUN_JSON" 2>/dev/null || true)"
  FAILED_JOBS="$(jq -c '[(.jobs // [])[] | select(.conclusion == "failure")
                        | {name: .name, steps: [(.steps // [])[] | select(.conclusion == "failure") | .name]}]' \
                 "$RUN_JSON" 2>/dev/null || echo '[]')"
fi
jq -r '.[].name' <<< "$FAILED_JOBS" > "$WORK/failed-job-names.txt"
jq -r '.[].steps[]' <<< "$FAILED_JOBS" > "$WORK/failed-step-names.txt"

# --- 2. The log, made readable -------------------------------------------------
# Strip colour codes, the "job<TAB>step<TAB>" prefix gh puts on --log-failed
# output, the timestamp, and URLs (a docs link is not a file in this repo).
CLEAN="$WORK/log.txt"
if [[ -f "$RAW_LOG" ]]; then
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[^\t]*\t[^\t]*\t//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s#[a-z]+://[^[:space:]]+##g' \
    "$RAW_LOG" > "$CLEAN"
else
  : > "$CLEAN"
fi

# --- 3. Files the log names ----------------------------------------------------
# Only lines that report a failure or carry a file:line reference are read, and
# a token has to exist in the checkout - directly, or as the unique suffix of a
# tracked path, which is how a test runner inside a package prints its files.
# A path that exists nowhere in the checkout is recorded separately: it is the
# strongest sign that the failure is about data this runner does not have.
git ls-files > "$WORK/tracked.txt" 2>/dev/null || : > "$WORK/tracked.txt"

resolve_path() {
  local tok="$1"
  tok="${tok#./}"
  tok="$(sed -E 's#^/home/runner/work/[^/]+/[^/]+/##; s#^/github/workspace/##' <<< "$tok")"
  [[ "$tok" == /* ]] && return 1
  [[ "$tok" =~ $NOISE_RE ]] && return 1
  if [[ -f "$tok" ]]; then echo "$tok"; return 0; fi
  local hits
  hits="$(grep -E "(^|/)$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$tok")\$" "$WORK/tracked.txt" || true)"
  if [[ -n "$hits" && "$(wc -l <<< "$hits")" -eq 1 ]]; then echo "$hits"; return 0; fi
  return 1
}

: > "$WORK/named-existing.txt"; : > "$WORK/named-missing.txt"; : > "$WORK/failing-tests.txt"
while IFS= read -r line; do
  [[ "$line" =~ $INTEREST_RE ]] || continue
  [[ "$line" =~ $PASS_LINE_RE ]] && continue
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if p="$(resolve_path "$tok")"; then
      echo "$p" >> "$WORK/named-existing.txt"
      is_test "$p" && echo "$p" >> "$WORK/failing-tests.txt"
    elif [[ "$tok" == */* && ! "$tok" =~ $NOISE_RE && "$tok" != /* ]]; then
      echo "${tok#./}" >> "$WORK/named-missing.txt"
    fi
  done < <(grep -oE "$PATH_RE" <<< "$line" || true)
done < "$CLEAN"

# --- 4. This branch's own diff -------------------------------------------------
PR_BASE=""
: > "$WORK/pr-files.txt"
BASE_NOTE=""
if [[ -n "$BASE_REF" ]]; then
  for cand in "origin/$BASE_REF" "$BASE_REF"; do
    if git rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then PR_BASE="$cand"; break; fi
  done
fi
if [[ -n "$PR_BASE" ]]; then
  mb="$(git merge-base "$PR_BASE" HEAD 2>/dev/null || true)"
  if [[ -n "$mb" && "$mb" != "$(git rev-parse HEAD)" ]]; then
    git diff --name-only "$mb" HEAD > "$WORK/pr-files.txt" 2>/dev/null
  else
    # HEAD is the base itself - a failure on the default branch. The only
    # change that can be blamed is the commit that just landed.
    git diff --name-only HEAD~1 HEAD > "$WORK/pr-files.txt" 2>/dev/null
    BASE_NOTE="HEAD is $PR_BASE itself, so the last commit stands in for the branch diff"
  fi
else
  BASE_NOTE="base ref '${BASE_REF:-<none>}' could not be resolved, so the branch's own diff is unknown"
fi
sorted "$WORK/pr-files.txt" | grep -Ev "$TEST_RE" > "$WORK/pr-src.txt" || true
sorted "$WORK/pr-files.txt" | grep -E  "$TEST_RE" > "$WORK/pr-tests.txt" || true

# --- 5. What the failing job reads ---------------------------------------------
# The block for the failing job is cut out of the workflow file and searched for
# a checkout of some other repository and for the markers that mean "this job
# needs data from outside": BRAIN_DIR, corpus, gate, e2e. actions/checkout also
# announces the repository it syncs, so the log is checked for that too.
OTHER_REPO=""
: > "$WORK/markers.txt"
JOB_BLOCK_FOUND=false
BLOCK="$WORK/job-block.txt"; : > "$BLOCK"

normalise_job() { sed -E 's/[[:space:]]*\(.*\)[[:space:]]*$//; s/^.* \/ //' <<< "$1"; }

if [[ -n "$WORKFLOW_PATH" && -f "$WORKFLOW_PATH" ]]; then
  # key<TAB>indent<TAB>line for every line inside jobs:, tagged with its job key.
  awk '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[^[:space:]#]/ { injobs=0 }
    injobs {
      n = match($0, /^[[:space:]]+/) ? RLENGTH : 0
      if ($0 ~ /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ && (ind == "" || n == ind)) {
        ind = n; key = $0; sub(/^[[:space:]]+/, "", key); sub(/:[[:space:]]*$/, "", key)
      }
      if (key != "") print key "\t" n "\t" $0
    }' "$WORKFLOW_PATH" > "$WORK/jobs-tagged.txt"

  while IFS= read -r want; do
    w="$(normalise_job "$want")"
    key=""
    if awk -F'\t' -v k="$w" '$1 == k { f=1 } END { exit !f }' "$WORK/jobs-tagged.txt"; then
      key="$w"
    else
      # Match on the job's display name: a `name:` two spaces deeper than the key.
      key="$(awk -F'\t' -v k="$w" '
        { ind[$1] = ($1 in ind) ? ind[$1] : $2 }
        $3 ~ /^[[:space:]]+name:/ && $2 == ind[$1] + 2 {
          v = $3; sub(/^[[:space:]]+name:[[:space:]]*/, "", v); gsub(/^["'"'"']|["'"'"']$/, "", v)
          sub(/[[:space:]]*\(.*\)[[:space:]]*$/, "", v)
          if (v == k) { print $1; exit }
        }' "$WORK/jobs-tagged.txt")"
    fi
    if [[ -n "$key" ]]; then
      awk -F'\t' -v k="$key" '$1 == k { print $3 }' "$WORK/jobs-tagged.txt" >> "$BLOCK"
      JOB_BLOCK_FOUND=true
    fi
  done < "$WORK/failed-job-names.txt"
  # No block matched: read the whole file rather than nothing.
  $JOB_BLOCK_FOUND || cat "$WORKFLOW_PATH" > "$BLOCK"
fi

if [[ -s "$BLOCK" ]]; then
  while IFS= read -r r; do
    [[ -z "$r" || "$r" == *'github.repository'* ]] && continue
    [[ "${r,,}" == "${REPO,,}" ]] && continue
    OTHER_REPO="$r"; break
  done < <(grep -oE 'repository:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]+' "$BLOCK" | sed -E 's/^repository:[[:space:]]*["'"'"']?//')
  { cat "$BLOCK" "$WORK/failed-job-names.txt" "$WORK/failed-step-names.txt"; } \
    | grep -oiE 'BRAIN_DIR|corpus|gate|e2e' | tr '[:upper:]' '[:lower:]' | sort -u > "$WORK/markers.txt"
fi
if [[ -z "$OTHER_REPO" ]]; then
  while IFS= read -r r; do
    [[ -n "$r" && "${r,,}" != "${REPO,,}" ]] && { OTHER_REPO="$r"; break; }
  done < <(grep -oE 'Syncing repository: [^[:space:]]+' "$CLEAN" | sed 's/^Syncing repository: //')
fi

# --- 6. What the failing files reach through their imports ---------------------
# A test that fails because of a change three files away is still this
# branch's doing. Relative imports are followed up to three hops; the fixer's
# import graph does not need to be perfect, only good enough to catch the
# common shape of "my change broke a test that exercises it".
IMPORT_DEPTH=3
FRONTIER_CAP=400

rel() { realpath -m --relative-to=. "$1" 2>/dev/null; }

resolve_js() {
  local p c; p="$(rel "$1")"; [[ -z "$p" || "$p" == ../* ]] && return
  for c in "$p" "$p.ts" "$p.tsx" "$p.mts" "$p.js" "$p.jsx" "$p.mjs" "$p.cjs" \
           "${p%.js}.ts" "${p%.js}.tsx" "${p%.mjs}.mts" "${p%.cjs}.cts" \
           "$p/index.ts" "$p/index.tsx" "$p/index.js"; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
}
resolve_py() {  # module path a.b.c relative to a directory
  local base="$1" mod="$2" c p; p="${mod//.//}"
  for c in "$base/$p.py" "$base/$p/__init__.py" "$base/src/$p.py" "$base/src/$p/__init__.py"; do
    c="$(rel "$c")"; [[ -n "$c" && "$c" != ../* && -f "$c" ]] && { echo "$c"; return; }
  done
}

imports_of() {
  local f="$1" d spec m dots
  d="$(dirname "$f")"
  case "${f##*.}" in
    ts|tsx|mts|cts|js|jsx|mjs|cjs)
      grep -oE "(from|import|require)[[:space:]]*\(?[[:space:]]*['\"]\.{1,2}/[^'\"]+['\"]" "$f" 2>/dev/null \
        | sed -E "s/^.*['\"](\.{1,2}\/[^'\"]+)['\"].*$/\1/" | sort -u \
        | while IFS= read -r spec; do resolve_js "$d/$spec"; done ;;
    py)
      grep -oE '^[[:space:]]*(from[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+import|import[[:space:]]+[A-Za-z0-9_.]+)' "$f" 2>/dev/null \
        | sed -E 's/^[[:space:]]*(from|import)[[:space:]]+//; s/[[:space:]]+import$//' | sort -u \
        | while IFS= read -r m; do
            if [[ "$m" == .* ]]; then
              dots="${m%%[!.]*}"; m="${m#"$dots"}"
              up="$d"; for ((i = 1; i < ${#dots}; i++)); do up="$up/.."; done
              [[ -n "$m" ]] && resolve_py "$up" "$m"
            else
              resolve_py . "$m"
            fi
          done ;;
    go)
      # Go tests share a package with their siblings; the package is the unit.
      [[ "$f" == *_test.go ]] && find "$d" -maxdepth 1 -name '*.go' ! -name '*_test.go' -type f 2>/dev/null | sed 's#^\./##' ;;
    rs)
      grep -oE '^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_]+' "$f" 2>/dev/null | awk '{print $NF}' \
        | while IFS= read -r m; do
            for c in "$d/$m.rs" "$d/$m/mod.rs"; do [[ -f "$c" ]] && rel "$c"; done
          done
      grep -oE 'use[[:space:]]+crate::[A-Za-z0-9_:]+' "$f" 2>/dev/null | sed -E 's/^use[[:space:]]+crate:://; s/::/\//g' \
        | while IFS= read -r m; do
            for c in "src/$m.rs" "src/$m/mod.rs" "src/${m%/*}.rs"; do [[ -f "$c" ]] && { echo "$c"; break; }; done
          done ;;
  esac
}

sorted "$WORK/named-existing.txt" > "$WORK/seeds.txt"
: > "$WORK/reach.txt"
cp "$WORK/seeds.txt" "$WORK/frontier.txt"
for ((depth = 1; depth <= IMPORT_DEPTH; depth++)); do
  [[ -s "$WORK/frontier.txt" ]] || break
  head -n "$FRONTIER_CAP" "$WORK/frontier.txt" > "$WORK/frontier-capped.txt"
  while IFS= read -r f; do imports_of "$f"; done < "$WORK/frontier-capped.txt" | sort -u > "$WORK/found.txt"
  minus "$WORK/found.txt" <(sorted "$WORK/reach.txt" "$WORK/seeds.txt" | sort -u) > "$WORK/next.txt"
  cat "$WORK/next.txt" >> "$WORK/reach.txt"
  cp "$WORK/next.txt" "$WORK/frontier.txt"
done

# --- 7. Classify ---------------------------------------------------------------
inter "$WORK/named-existing.txt" "$WORK/pr-src.txt"   > "$WORK/direct-src.txt"
cat "$WORK/failing-tests.txt" "$WORK/named-existing.txt" | inter /dev/stdin "$WORK/pr-tests.txt" > "$WORK/direct-tests.txt"
inter "$WORK/reach.txt" "$WORK/pr-src.txt" | minus /dev/stdin "$WORK/direct-src.txt" > "$WORK/reach-src.txt"
inter "$WORK/failing-tests.txt" "$WORK/pr-files.txt" > "$WORK/intersection.txt"

STRONG_ENV=false; [[ -n "$OTHER_REPO" || -s "$WORK/named-missing.txt" ]] && STRONG_ENV=true
WEAK_ENV=false;   [[ -s "$WORK/markers.txt" ]] && WEAK_ENV=true

CLASS=""; STOP=false; REASON=""
: > "$WORK/allowed.txt"

describe_env() {
  local bits=()
  [[ -n "$OTHER_REPO" ]] && bits+=("the failing job checks out another repository (\`$OTHER_REPO\`)")
  [[ -s "$WORK/named-missing.txt" ]] && bits+=("the log names files that do not exist in this checkout ($(joined "$WORK/named-missing.txt" | cut -c1-200))")
  [[ -s "$WORK/markers.txt" ]] && bits+=("the job carries external-data markers ($(joined "$WORK/markers.txt"))")
  local out="" b
  for b in "${bits[@]}"; do out="${out:+$out; }$b"; done
  echo "$out"
}

if [[ -s "$WORK/direct-src.txt" ]]; then
  CLASS="code"
  sorted "$WORK/direct-src.txt" "$WORK/reach-src.txt" "$WORK/pr-files.txt" | sort -u > "$WORK/allowed.txt"
  REASON="the log names source this branch changed ($(joined "$WORK/direct-src.txt"))"
elif [[ -s "$WORK/reach-src.txt" ]] && ! $STRONG_ENV; then
  CLASS="code"
  sorted "$WORK/reach-src.txt" "$WORK/pr-files.txt" | sort -u > "$WORK/allowed.txt"
  REASON="the failing files import source this branch changed ($(joined "$WORK/reach-src.txt"))"
elif [[ -s "$WORK/direct-tests.txt" ]]; then
  CLASS="test"
  sorted "$WORK/failing-tests.txt" "$WORK/direct-tests.txt" | sort -u > "$WORK/allowed.txt"
  REASON="the only implicated files are tests this branch changed ($(joined "$WORK/direct-tests.txt"))"
elif $STRONG_ENV || $WEAK_ENV; then
  CLASS="env-data"; STOP=true
  REASON="not caused by this branch: none of the files it changed ($(joined "$WORK/pr-files.txt" | cut -c1-300)) is implicated, and $(describe_env)"
else
  CLASS="unlinked"; STOP=true
  REASON="could not link the failure to this branch: nothing it changed ($(joined "$WORK/pr-files.txt" | cut -c1-300)) is named in the log or reachable from the failing files ($(joined "$WORK/named-existing.txt" | cut -c1-200))"
fi
[[ -n "$BASE_NOTE" ]] && REASON="$REASON; $BASE_NOTE"

# --- 8. Write it down ----------------------------------------------------------
jq -n \
  --arg class "$CLASS" --argjson stop "$STOP" --arg reason "$REASON" \
  --argjson failed_jobs "$FAILED_JOBS" \
  --argjson failing_tests "$(as_json_array "$WORK/failing-tests.txt")" \
  --argjson log_named_files "$(as_json_array "$WORK/named-existing.txt")" \
  --argjson log_named_missing "$(as_json_array "$WORK/named-missing.txt")" \
  --arg pr_base "${PR_BASE:-}" --arg base_note "$BASE_NOTE" \
  --argjson pr_files "$(as_json_array "$WORK/pr-files.txt")" \
  --argjson intersection "$(as_json_array "$WORK/intersection.txt")" \
  --argjson implicated_source "$(as_json_array "$WORK/direct-src.txt")" \
  --argjson reachable_source "$(as_json_array "$WORK/reach-src.txt")" \
  --argjson implicated_tests "$(as_json_array "$WORK/direct-tests.txt")" \
  --arg other_repository "$OTHER_REPO" \
  --argjson markers "$(as_json_array "$WORK/markers.txt")" \
  --argjson job_block_found "$JOB_BLOCK_FOUND" \
  --arg workflow "$WORKFLOW_PATH" \
  --argjson allowed_paths "$(as_json_array "$WORK/allowed.txt")" \
  '{class: $class, stop: $stop, reason: $reason,
    failed_jobs: $failed_jobs, failing_tests: $failing_tests,
    log_named_files: $log_named_files, log_named_missing: $log_named_missing,
    pr_base: $pr_base, base_note: $base_note, pr_files: $pr_files,
    intersection: $intersection, implicated_source: $implicated_source,
    reachable_source: $reachable_source, implicated_tests: $implicated_tests,
    env: {other_repository: $other_repository, markers: $markers,
          job_block_found: $job_block_found, workflow: $workflow},
    allowed_paths: $allowed_paths}' > "$OUT"

{
  echo "class=$CLASS"
  echo "stop=$STOP"
  echo "reason=$(tr '\n' ' ' <<< "$REASON" | sed 's/ *$//')"
  echo "allowed_paths=$(joined "$WORK/allowed.txt")"
  echo "failing_tests=$(joined "$WORK/failing-tests.txt")"
  echo "path=$OUT"
  echo "json=$(jq -c . "$OUT")"
} >> "$GITHUB_OUTPUT"

{
  echo "## Diagnosis"
  echo
  echo "**Class: \`$CLASS\`** - $REASON"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Failed jobs | $(jq -r '[.[] | .name] | join(", ")' <<< "$FAILED_JOBS") |"
  echo "| Failing tests | $(joined "$WORK/failing-tests.txt") |"
  echo "| Files named in the log | $(joined "$WORK/named-existing.txt" | cut -c1-300) |"
  echo "| Named but not in this checkout | $(joined "$WORK/named-missing.txt" | cut -c1-300) |"
  echo "| This branch changed | $(joined "$WORK/pr-files.txt" | cut -c1-300) |"
  echo "| Files the fixer may change | $(joined "$WORK/allowed.txt") |"
  echo
} >> "$GITHUB_STEP_SUMMARY"

echo "Diagnosis: class=$CLASS stop=$STOP"
echo "  $REASON"
