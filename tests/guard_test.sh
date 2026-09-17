#!/usr/bin/env bash
# Tests for every script that decides something: the honesty guard, the
# diagnosis, the scope it turns into, verification's insistence that the failing
# test ran, the second opinion's verdict, and where the fix is allowed to land.
#
# Each case builds a throwaway git repo, makes the kind of change a cornered
# agent might make or feeds the kind of log CI actually produces, and checks the
# verdict. These scripts are the only thing standing between "CI is green" and
# "CI was silenced", so they get real tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL+1)); }

sandbox() {
  local dir; dir="$(mktemp -d)"
  cd "$dir" || exit 1
  git init -q -b main
  git config user.email t@example.com
  git config user.name Test
  mkdir -p src tests .github/workflows

  cat > src/adder.js <<'EOF2'
function add(a, b) { return a - b; }
module.exports = { add };
EOF2

  cat > tests/adder.test.js <<'EOF2'
const { add } = require('../src/adder');
test('adds two numbers', () => {
  expect(add(2, 2)).toBe(4);
});
test('adds negatives', () => {
  expect(add(-1, -1)).toBe(-2);
});
EOF2

  cat > package.json <<'EOF2'
{ "name": "sandbox", "scripts": { "test": "jest", "lint": "eslint ." } }
EOF2

  cat > .github/workflows/ci.yml <<'EOF2'
name: CI
on: [push]
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - run: npm ci
      - run: npm test
EOF2

  git add -A && git commit -qm "initial"
  echo "$dir"
}

# A diagnosis file naming the given allowed paths; the failing test is fixed.
write_diag() {  # out, allowed paths...
  local out="$1"; shift
  jq -n --arg class code --argjson allowed "$(printf '%s\n' "$@" | grep -v '^$' | jq -R . | jq -s .)" \
    '{class: $class, stop: false, reason: "test fixture", failing_tests: ["tests/adder.test.js"], allowed_paths: $allowed}' > "$out"
}

fingerprint_now() {
  export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
  OUT="$1" bash "$ROOT/scripts/fingerprint.sh" > /dev/null
}

# name, expected exit (0 = allowed, 1 = blocked), commands that make the change,
# [allowed paths, space separated; "-" for no diagnosis at all], [extra env]
check() {
  local name="$1" expect="$2" mutate="$3" allowed="${4:-src/adder.js tests/adder.test.js}" extra="${5:-}"
  local dir base rc
  dir="$(sandbox)"
  cd "$dir" || return
  base="$(git rev-parse HEAD)"

  local tmp; tmp="$(mktemp -d)"
  RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"

  bash -c "$mutate" >/dev/null 2>&1
  git add -A >/dev/null 2>&1
  git commit -qm "fix: attempt" --allow-empty >/dev/null 2>&1

  export RUNNER_TEMP="$tmp"
  export GITHUB_OUTPUT="$tmp/out"; : > "$GITHUB_OUTPUT"
  export GITHUB_STEP_SUMMARY="$tmp/summary"; : > "$GITHUB_STEP_SUMMARY"
  export FINGERPRINT_BEFORE="$tmp/before.json"
  export BASE_SHA="$base"
  if [[ "$allowed" == "-" ]]; then
    unset DIAGNOSIS
  else
    # shellcheck disable=SC2086
    write_diag "$tmp/diagnosis.json" $allowed
    export DIAGNOSIS="$tmp/diagnosis.json"
  fi
  env $extra bash "$ROOT/scripts/honesty-guard.sh" > "$tmp/log" 2>&1
  rc=$?

  if [[ "$rc" == "$expect" ]]; then
    ok "$name"
  else
    bad "$name" "expected exit $expect, got $rc"
    sed 's/^/          /' "$tmp/log" | head -12
  fi
  cd "$ROOT" || return
  rm -rf "$dir" "$tmp"
}

echo "honesty guard"

# --- the honest fix must be allowed through --------------------------------
check "allows fixing the actual bug" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js"

check "allows adding a test alongside the fix" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js
   printf \"test('adds zero', () => { expect(add(0,0)).toBe(0); });\n\" >> tests/adder.test.js"

# --- every way of buying a green tick must be blocked ----------------------
check "blocks deleting the test file" 1 \
  "rm tests/adder.test.js"

check "blocks skipping a test" 1 \
  "sed -i \"s/^test('adds two numbers'/test.skip('adds two numbers'/\" tests/adder.test.js"

check "blocks xit" 1 \
  "sed -i \"s/^test('adds negatives'/xit('adds negatives'/\" tests/adder.test.js"

check "blocks removing an assertion" 1 \
  "sed -i '/adds negatives/,+2d' tests/adder.test.js"

check "blocks continue-on-error in CI" 1 \
  "sed -i 's|      - run: npm test|      - run: npm test\n        continue-on-error: true|' .github/workflows/ci.yml" \
  "src/adder.js .github/workflows/ci.yml"

check "blocks removing a CI step" 1 \
  "sed -i '/- run: npm test/d' .github/workflows/ci.yml" \
  "src/adder.js .github/workflows/ci.yml"

check "blocks || true in CI" 1 \
  "sed -i 's|- run: npm test|- run: npm test \|\| true|' .github/workflows/ci.yml" \
  "src/adder.js .github/workflows/ci.yml"

check "blocks hollowing out the test script" 1 \
  "sed -i 's|\"test\": \"jest\"|\"test\": \"true\"|' package.json" \
  "src/adder.js package.json"

check "blocks --no-verify" 1 \
  "printf 'git commit --no-verify\n' > scripts.sh" \
  "src/adder.js scripts.sh"

check "blocks touching hook config" 1 \
  "printf 'pre-commit:\n  commands: {}\n' > lefthook.yml" \
  "src/adder.js lefthook.yml"

check "blocks a commit that changes nothing" 1 "true"

check "blocks editing its own rules" 1 \
  "mkdir -p scripts && printf 'exit 0\n' > scripts/honesty-guard.sh" \
  "src/adder.js scripts/honesty-guard.sh"

check "blocks editing its own tests" 1 \
  "mkdir -p tests && printf 'exit 0\n' > tests/guard_test.sh" \
  "src/adder.js tests/guard_test.sh"

# --- the diagnosed scope is the box --------------------------------------
echo "  -- scope"
check "allows a fix that stays inside the diagnosed scope" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js" \
  "src/adder.js"

check "blocks editing a test the diagnosis did not implicate" 1 \
  "sed -i 's/a - b/a + b/' src/adder.js
   printf \"test('adds zero', () => { expect(add(0,0)).toBe(0); });\n\" >> tests/adder.test.js" \
  "src/adder.js"

check "blocks touching a source file the diagnosis did not name" 1 \
  "sed -i 's/a - b/a + b/' src/adder.js
   printf 'module.exports = {};\n' > src/other.js" \
  "src/adder.js"

check "blocks any change when there is no diagnosis at all" 1 \
  "sed -i 's/a - b/a + b/' src/adder.js" \
  "-"

# --- and it has a size ------------------------------------------------------
echo "  -- size caps"
check "allows a fix within the caps" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js" \
  "src/adder.js" "MAX_CHANGED_FILES=1 MAX_CHANGED_LINES=4"

check "blocks a fix that touches too many files" 1 \
  "sed -i 's/a - b/a + b/' src/adder.js
   printf '// a\n' > src/a.js; printf '// b\n' > src/b.js" \
  "src/adder.js src/a.js src/b.js" "MAX_CHANGED_FILES=2"

check "blocks a fix that changes too many lines" 1 \
  "for i in \$(seq 1 30); do printf '// line %s\n' \$i >> src/adder.js; done" \
  "src/adder.js" "MAX_CHANGED_LINES=20"

# --- history must only ever grow -------------------------------------------
echo "  -- history"
dir="$(sandbox)"; cd "$dir" || exit 1
base="$(git rev-parse HEAD)"
tmp="$(mktemp -d)"
RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"
write_diag "$tmp/diagnosis.json" src/adder.js
sed -i 's/a - b/a + b/' src/adder.js
git add -A && git commit -qm "fix"
git commit -q --amend -m "fix: rewritten" # simulates an amend after the base
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" \
       FINGERPRINT_BEFORE="$tmp/before.json" BASE_SHA="$base" DIAGNOSIS="$tmp/diagnosis.json"
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
# An amend of a commit made after BASE_SHA still keeps BASE_SHA as an ancestor,
# so this one should pass. Rewriting BASE_SHA itself is what must fail.
if bash "$ROOT/scripts/honesty-guard.sh" >/dev/null 2>&1; then
  ok "allows amending the fix commit itself"
else
  bad "allows amending the fix commit itself"
fi
cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"

# Squashing away the commit the workflow started from drops it out of history,
# which is the shape a reset or rebase takes when it eats someone else's work.
dir="$(sandbox)"; cd "$dir" || exit 1
git commit -q --allow-empty -m "someone else's commit"
base="$(git rev-parse HEAD)"
tmp="$(mktemp -d)"
RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"
write_diag "$tmp/diagnosis.json" src/adder.js
sed -i 's/a - b/a + b/' src/adder.js
git add -A && git commit -qm "fix"
git reset -q --soft "$(git rev-parse HEAD~2)"
git commit -qm "fix, squashed over the base"
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" \
       FINGERPRINT_BEFORE="$tmp/before.json" BASE_SHA="$base" DIAGNOSIS="$tmp/diagnosis.json"
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
if bash "$ROOT/scripts/honesty-guard.sh" >/dev/null 2>&1; then
  bad "blocks rewritten history"
else
  ok "blocks rewritten history"
fi
cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"
unset DIAGNOSIS

# ============================================================================
echo
echo "diagnosis"

# A repo with a main branch, the extra files the cases need, and a feature
# branch whose commit is "this branch's own diff".
FIXTURE_WORKFLOW="$(cat <<'EOF2'
name: ci
on: [push]
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npm test
  brain-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Check out the brain (read-only)
        uses: actions/checkout@v7
        with:
          repository: example-org/private-brain
          path: .brain
      - name: Run the brain-dependent suites
        env:
          BRAIN_DIR: ${{ github.workspace }}/.brain
        run: npx vitest run tests/hard-*.test.ts
  py:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: pytest
EOF2
)"

sandbox_pr() {  # mutate commands for the feature branch
  local dir; dir="$(sandbox)"
  cd "$dir" || exit 1
  mkdir -p lib pkg
  printf 'export function parseFrontmatter(s) { return s; }\n' > lib/frontmatter.ts
  printf 'export function health() { return "ok"; }\n' > lib/health.ts
  printf 'import { parseFrontmatter } from "../lib/frontmatter";\nimport { existsSync } from "node:fs";\ndescribe.skipIf(!existsSync(process.env.BRAIN_DIR ?? ""))("live brain corpus", () => {});\n' > tests/hard-router.test.ts
  printf 'import { health } from "../lib/health";\ntest("x", () => {});\n' > tests/health.test.ts
  printf 'def add(a, b):\n    return a - b\n' > pkg/adder.py
  printf 'from pkg.adder import add\n\ndef test_add():\n    assert add(2, 2) == 4\n' > tests/test_adder.py
  printf '# readme\n' > README.md
  printf '%s\n' "$FIXTURE_WORKFLOW" > .github/workflows/ci.yml
  git add -A && git commit -qm "base"
  git checkout -q -b feature
  bash -c "$1" >/dev/null 2>&1
  git add -A && git commit -qm "feature change"
  echo "$dir"
}

run_json() {  # failing job name
  printf '{"path": ".github/workflows/ci.yml", "jobs": [{"name": "%s", "conclusion": "failure", "steps": [{"name": "Run tests", "conclusion": "failure"}]}, {"name": "other", "conclusion": "success", "steps": []}]}\n' "$1"
}

# name, expected class, expected stop, expected allowed (space separated), failing job, mutate, log file
diag_case() {
  local name="$1" want_class="$2" want_stop="$3" want_allowed="$4" job="$5" mutate="$6" logfile="$7"
  local dir tmp got_class got_stop got_allowed
  dir="$(sandbox_pr "$mutate")"
  cd "$dir" || exit 1
  tmp="$(mktemp -d)"
  run_json "$job" > "$tmp/run.json"
  cp "$logfile" "$tmp/raw.log"
  RUNNER_TEMP="$tmp" RUN_JSON="$tmp/run.json" RAW_LOG="$tmp/raw.log" REPO=example-org/sandbox BASE_REF=main \
    DIAGNOSIS_OUT="$tmp/diagnosis.json" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" \
    bash "$ROOT/scripts/diagnose.sh" > "$tmp/log" 2>&1
  got_class="$(jq -r '.class' "$tmp/diagnosis.json" 2>/dev/null)"
  got_stop="$(jq -r '.stop' "$tmp/diagnosis.json" 2>/dev/null)"
  got_allowed="$(jq -r '.allowed_paths | join(" ")' "$tmp/diagnosis.json" 2>/dev/null)"
  if [[ "$got_class" == "$want_class" && "$got_stop" == "$want_stop" && "$got_allowed" == "$want_allowed" ]]; then
    ok "$name"
  else
    bad "$name" "got class=$got_class stop=$got_stop allowed='$got_allowed'; wanted class=$want_class stop=$want_stop allowed='$want_allowed'"
    sed 's/^/          /' "$tmp/log" | head -6
  fi
  LAST_DIAG="$tmp/diagnosis.json"
  cd "$ROOT" || exit 1; rm -rf "$dir"
}

LOGS="$(mktemp -d)"

# The motivating shape: coloured vitest output with gh's job/step/timestamp
# prefix, a FAIL in a test this branch never touched, an assertion about a file
# that only exists in another repository's checkout.
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z \033[32m✓\033[39m tests/health.test.ts \033[2m(\033[22m1 test\033[2m)\033[22m 12ms\n' > "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z \033[31m❯\033[39m tests/hard-router.test.ts (8 tests | 1 failed) 105ms\n' >> "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z \033[41m FAIL \033[49m tests/hard-router.test.ts > live brain corpus > reads a description out of every note\n' >> "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z \033[31mAssertionError\033[39m: notes/example-note.md description: expected 0 to be greater than 10\n' >> "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z  ❯ tests/hard-router.test.ts:84:60\n' >> "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z See https://example.com/docs/guide.md for details\n' >> "$LOGS/env.log"
printf 'brain-gate\tRun the brain-dependent suites\t2026-09-16T13:25:01.1234567Z ##[error]Process completed with exit code 1.\n' >> "$LOGS/env.log"

diag_case "stops on a failure caused by data in another checkout (the #202 shape)" \
  env-data true "" brain-gate \
  "sed -i 's/ok/stale/' lib/health.ts; printf 'test(\"y\", () => {});\n' >> tests/health.test.ts" \
  "$LOGS/env.log"
if [[ "$(jq -r '.failing_tests | join(" ")' "$LAST_DIAG")" == "tests/hard-router.test.ts" \
   && "$(jq -r '.log_named_missing | join(" ")' "$LAST_DIAG")" == "notes/example-note.md" \
   && "$(jq -r '.env.other_repository' "$LAST_DIAG")" == "example-org/private-brain" ]]; then
  ok "  ...and records the failing test, the missing file and the other repository"
else
  bad "  ...and records the failing test, the missing file and the other repository" "$(jq -c '{failing_tests, log_named_missing, env}' "$LAST_DIAG")"
fi

# Same failure, but this time the job block has no other repository and the
# log names nothing missing: still not this branch's, and still a stop.
printf 'ci\tRun tests\t2026-09-16T13:25:01.1234567Z FAIL tests/hard-router.test.ts > live brain corpus > routes every note\n ❯ tests/hard-router.test.ts:84:60\n' > "$LOGS/unlinked.log"
diag_case "stops when nothing this branch changed is implicated and nothing explains it" \
  unlinked true "" ci \
  "printf 'more\n' >> README.md" \
  "$LOGS/unlinked.log"

diag_case "stops as env-data on the other-repository checkout alone" \
  env-data true "" brain-gate \
  "printf 'more\n' >> README.md" \
  "$LOGS/unlinked.log"

# The log names the source this branch changed: fix the code, inside the
# branch's own files plus what the log named.
printf 'ci\tRun tests\t2026-09-16T13:25:01.1234567Z FAIL tests/adder.test.js\n  ● adds two numbers\n    expect(received).toBe(expected)\n      at Object.<anonymous> (tests/adder.test.js:3:22)\n      at add (src/adder.js:1:30)\n' > "$LOGS/code.log"
diag_case "classes a failure in source this branch changed as code" \
  code false "src/adder.js" ci \
  "sed -i 's/a - b/a * b/' src/adder.js" \
  "$LOGS/code.log"

# The log names only the test, but the test imports the source this branch
# changed: still code, and the test is not in the allowed list.
printf 'ci\tRun tests\t2026-09-16T13:25:01.1234567Z FAIL tests/adder.test.js\n  ● adds two numbers\n    expect(received).toBe(expected)\n      at Object.<anonymous> (tests/adder.test.js:3:22)\n' > "$LOGS/reach.log"
diag_case "follows the failing test's imports to source this branch changed" \
  code false "src/adder.js" ci \
  "sed -i 's/a - b/a * b/' src/adder.js" \
  "$LOGS/reach.log"

# pytest shape, with the source reached through a package import.
printf 'py\tRun tests\t2026-09-16T13:25:01.1234567Z FAILED tests/test_adder.py::test_add - assert 0 == 4\n' > "$LOGS/py.log"
diag_case "reads pytest output and follows a package import" \
  code false "pkg/adder.py" py \
  "sed -i 's/a - b/a * b/' pkg/adder.py" \
  "$LOGS/py.log"

# Only the test changed on this branch, and it is the one failing: the test
# may be edited, and nothing else.
diag_case "classes a failure in a test this branch changed as test, allowing that test only" \
  test false "tests/adder.test.js" ci \
  "sed -i 's/toBe(4)/toBe(5)/' tests/adder.test.js" \
  "$LOGS/reach.log"

# A passing file whose name contains a failure word is not a failing test.
printf 'ci\tRun tests\t2026-09-16T13:25:01.1234567Z ✓ tests/error-handling.test.js (3 tests) 4ms\nFAIL tests/adder.test.js\n      at add (src/adder.js:1:30)\n' > "$LOGS/passline.log"
diag_case "ignores a passing file whose name says error" \
  code false "src/adder.js" ci \
  "sed -i 's/a - b/a * b/' src/adder.js; printf 'test(\"e\", () => {});\n' > tests/error-handling.test.js" \
  "$LOGS/passline.log"
if ! jq -e '.failing_tests | index("tests/error-handling.test.js")' "$LAST_DIAG" >/dev/null; then
  ok "  ...and does not list it as failing"
else
  bad "  ...and does not list it as failing"
fi
rm -rf "$LOGS"

# ============================================================================
echo
echo "scope settings"

dir="$(sandbox)"; cd "$dir" || exit 1
printf 'test("o", () => {});\n' > tests/other.test.js
printf '[tool]\nname = "x"\n' > pyproject.toml
git add -A && git commit -qm "more files"
tmp="$(mktemp -d)"
write_diag "$tmp/diagnosis.json" src/adder.js tests/adder.test.js
RUNNER_TEMP="$tmp" DIAGNOSIS="$tmp/diagnosis.json" SETTINGS_OUT="$tmp/settings.json" GITHUB_OUTPUT="$tmp/out" \
  bash "$ROOT/scripts/scope-settings.sh" > "$tmp/log" 2>&1
DENY="$(jq -r '.permissions.deny[]' "$tmp/settings.json" 2>/dev/null)"
if grep -qxF 'Edit(tests/other.test.js)' <<< "$DENY" && ! grep -qxF 'Edit(tests/**)' <<< "$DENY" && ! grep -qxF 'Edit(tests/adder.test.js)' <<< "$DENY"; then
  ok "enumerates the test directory file by file when one test is allowed"
else
  bad "enumerates the test directory file by file when one test is allowed" "$(tr '\n' ' ' <<< "$DENY" | cut -c1-200)"
fi
if grep -qxF 'Edit(**/*.test.*)' <<< "$DENY" && grep -qxF 'Edit(!tests/adder.test.js)' <<< "$DENY" \
   && (( $(grep -nxF 'Edit(!tests/adder.test.js)' <<< "$DENY" | cut -d: -f1) > $(grep -nxF 'Edit(**/*.test.*)' <<< "$DENY" | cut -d: -f1) )); then
  ok "carves the allowed test out of the file pattern, after the pattern"
else
  bad "carves the allowed test out of the file pattern, after the pattern"
fi
if grep -qxF 'Edit(package.json)' <<< "$DENY" && grep -qxF 'Edit(*.toml)' <<< "$DENY" && grep -qxF 'Edit(.github/**)' <<< "$DENY" && grep -qxF 'Edit(.ci-autofix/**)' <<< "$DENY"; then
  ok "denies manifests, lockfiles, workflows and the toolkit"
else
  bad "denies manifests, lockfiles, workflows and the toolkit"
fi
if ! grep -q '^Write(\|^MultiEdit(\|^NotebookEdit(' <<< "$DENY"; then
  ok "writes only Edit() path rules, the ones Claude Code consults"
else
  bad "writes only Edit() path rules, the ones Claude Code consults"
fi

write_diag "$tmp/diagnosis.json" src/adder.js
RUNNER_TEMP="$tmp" DIAGNOSIS="$tmp/diagnosis.json" SETTINGS_OUT="$tmp/settings.json" GITHUB_OUTPUT="$tmp/out" \
  bash "$ROOT/scripts/scope-settings.sh" > "$tmp/log" 2>&1
DENY="$(jq -r '.permissions.deny[]' "$tmp/settings.json" 2>/dev/null)"
if grep -qxF 'Edit(tests/**)' <<< "$DENY" && ! grep -q '^Edit(!' <<< "$DENY"; then
  ok "denies the whole test directory when no test is allowed"
else
  bad "denies the whole test directory when no test is allowed"
fi
cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"

# ============================================================================
echo
echo "verification"

verify_case() {  # name, expected exit, expected could_not_run substring, output the test command prints
  local name="$1" expect="$2" want="$3" output="$4"
  local dir tmp rc got
  dir="$(sandbox)"; cd "$dir" || exit 1
  tmp="$(mktemp -d)"
  printf '%s\n' "$output" > "$tmp/suite.txt"
  write_diag "$tmp/diagnosis.json" src/adder.js
  RUNNER_TEMP="$tmp" DIAGNOSIS="$tmp/diagnosis.json" TEST_COMMAND="cat $tmp/suite.txt" SETUP_COMMAND="true" \
    BASE_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" \
    bash "$ROOT/scripts/verify.sh" > "$tmp/log" 2>&1
  rc=$?
  got="$(sed -n 's/^could_not_run=//p' "$tmp/out" | tail -1)"
  if [[ "$rc" == "$expect" && "$got" == *"$want"* ]]; then
    ok "$name"
  else
    bad "$name" "exit $rc, could_not_run='$got'"
    sed 's/^/          /' "$tmp/log" | head -6
  fi
  cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"
}

verify_case "passes when the failing test ran here" 0 "" \
  " ✓ tests/adder.test.js (2 tests) 12ms

 Test Files  1 passed (1)
      Tests  2 passed (2)"

verify_case "refuses when the failing test skipped itself here (vitest)" 1 "tests/adder.test.js (skipped here)" \
  " ↓ tests/adder.test.js (2 tests | 2 skipped)

 Test Files  1 skipped (1)
      Tests  2 skipped (2)"

verify_case "refuses when the failing test never ran here" 1 "tests/adder.test.js (did not run here)" \
  " ✓ tests/other.test.js (1 test) 3ms

 Test Files  1 passed (1)"

verify_case "refuses when pytest skipped every case in the file" 1 "(skipped here)" \
  "tests/adder.test.js ss                                              [100%]
2 skipped in 0.01s"

# ============================================================================
echo
echo "second opinion"

opinion_case() {  # name, expected exit, expected verdict, transcript JSON (or "-" for none)
  local name="$1" expect="$2" want="$3" json="$4"
  local tmp rc got
  tmp="$(mktemp -d)"
  [[ "$json" != "-" ]] && printf '%s\n' "$json" > "$tmp/exec.json"
  EXECUTION_FILE="$( [[ "$json" != "-" ]] && echo "$tmp/exec.json" || echo "$tmp/missing.json")" \
    VERDICT_OUT="$tmp/verdict.txt" RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" \
    bash "$ROOT/scripts/second-opinion.sh" > "$tmp/log" 2>&1
  rc=$?
  got="$(sed -n 's/^verdict=//p' "$tmp/out" | tail -1)"
  if [[ "$rc" == "$expect" && "$got" == "$want" ]]; then
    ok "$name"
  else
    bad "$name" "exit $rc, verdict='$got'"
  fi
  LAST_OUT="$tmp/out"
}

opinion_case "approves on a final VERDICT: APPROVE" 0 APPROVE \
  '[{"type":"user","message":{"content":[{"type":"text","text":"End with VERDICT: APPROVE or VERDICT: REJECT - why"}]}},{"type":"assistant","message":{"content":[{"type":"text","text":"Scope: fine. Cause: fine.\n\nVERDICT: APPROVE"}]}},{"type":"result","result":"Scope: fine. Cause: fine.\n\nVERDICT: APPROVE"}]'

opinion_case "rejects on VERDICT: REJECT and keeps the reason" 1 REJECT \
  '[{"type":"assistant","message":{"content":[{"type":"text","text":"The diff loosens the assertion.\n\nVERDICT: REJECT - the assertion in tests/adder.test.js was loosened rather than the code fixed"}]}}]'
if grep -q '^reason=the assertion in tests/adder.test.js was loosened' "$LAST_OUT"; then
  ok "  ...verbatim"
else
  bad "  ...verbatim" "$(grep '^reason=' "$LAST_OUT")"
fi

opinion_case "rejects when the reviewer gives no verdict" 1 REJECT \
  '[{"type":"assistant","message":{"content":[{"type":"text","text":"I looked at it and it seems okay I suppose."}]}}]'

opinion_case "rejects when there is no transcript at all" 1 REJECT "-"

opinion_case "reads only the reviewer's words, not the prompt that told it the format" 1 REJECT \
  '[{"type":"user","message":{"content":[{"type":"text","text":"VERDICT: APPROVE\nVERDICT: APPROVE"}]}},{"type":"assistant","message":{"content":[{"type":"text","text":"VERDICT: REJECT - it edits a test the branch did not change"}]}}]'

opinion_case "takes the last verdict when the reviewer thinks aloud first" 0 APPROVE \
  '[{"type":"assistant","message":{"content":[{"type":"text","text":"If the cause were wrong I would say VERDICT: REJECT. It is not.\n\n**VERDICT: APPROVE**"}]}}]'

# ============================================================================
echo
echo "push"

# A local bare origin, a fake gh that records what it was asked and can be told
# to refuse the pull request the way GitHub does when Actions may not open one.
push_case() {  # name, expected exit, mode, verdict, verified, refuse (true/false), expectation function
  local name="$1" expect="$2" mode="$3" verdict="$4" verified="$5" refuse="$6" expectation="$7"
  local dir tmp rc base fix
  dir="$(sandbox)"; cd "$dir" || exit 1
  tmp="$(mktemp -d)"
  git init -q --bare "$tmp/origin.git"
  git remote add origin "$tmp/origin.git"
  git checkout -q -b feature
  git push -q origin main feature
  base="$(git rev-parse HEAD)"
  sed -i 's/a - b/a + b/' src/adder.js
  git add -A && git commit -qm "fix: add, not subtract" -m "What was broken: the adder subtracted."
  fix="$(git rev-parse HEAD)"
  write_diag "$tmp/diagnosis.json" src/adder.js
  mkdir -p "$tmp/audit"; git diff "$base..HEAD" > "$tmp/audit/fix.diff"

  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "----- gh $*" >> "$FAKE_GH_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_GH_LOG"; done
case "$1 $2" in
  "pr create")
    if [[ "${FAKE_GH_REFUSE:-false}" == "true" ]]; then
      echo "pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)" >&2
      exit 1
    fi
    echo "https://example.com/pr/1" ;;
  "issue list"|"pr list") echo '[]' ;;
  *) : ;;
esac
EOF2
  chmod +x "$tmp/bin/gh"

  PATH="$tmp/bin:$PATH" FAKE_GH_LOG="$tmp/gh.log" FAKE_GH_REFUSE="$refuse" \
    RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" GITHUB_RUN_ID=42 \
    GH_REPO=example-org/sandbox BRANCH=feature PROTECTED=false PR_NUMBER="" BASE_SHA="$base" PUSH_TOKEN="" \
    PUSH_MODE="$mode" VERDICT="$verdict" VERDICT_REASON="" VERIFIED="$verified" DIAGNOSIS="$tmp/diagnosis.json" \
    AUDIT_URL="https://example.com/artifact" AUDIT_DIR="$tmp/audit" ATTEMPT=1 MAX_ATTEMPTS=3 FAILED_RUN_URL="https://example.com/run" \
    bash "$ROOT/scripts/push-fix.sh" > "$tmp/log" 2>&1
  rc=$?
  local origin_feature fixbranch
  origin_feature="$(git -C "$tmp/origin.git" rev-parse --verify -q refs/heads/feature 2>/dev/null || true)"
  fixbranch="$(git -C "$tmp/origin.git" rev-parse --verify -q refs/heads/claude/ci-autofix/feature-42 2>/dev/null || true)"
  if [[ "$rc" == "$expect" ]] && $expectation "$origin_feature" "$fixbranch" "$base" "$fix" "$tmp/gh.log" "$tmp/out"; then
    ok "$name"
  else
    bad "$name" "exit $rc (wanted $expect); origin/feature=${origin_feature:0:8} base=${base:0:8} fix=${fix:0:8} fixbranch=${fixbranch:0:8}"
    sed 's/^/          /' "$tmp/log" | head -8
  fi
  cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"
}

# expectation helpers: origin_feature, fixbranch, base, fix, gh log, outputs
pr_opened()   { [[ "$1" == "$3" && "$2" == "$4" ]] && grep -q '^pr$' "$5" && grep -q 'ci-autofix-fix-for:feature@' "$5" && grep -q 'Second opinion: \*\*APPROVE\*\*' "$5" && grep -q '^pushed=true' "$6"; }
pr_refused()  { [[ "$1" == "$3" && "$2" == "$4" ]] && grep -q '^handoff_posted=true' "$6" && grep -q '^pushed=false' "$6" && grep -q '^issue$' "$5" && grep -q 'not permitted to create' "$5" && grep -q '^+function add(a, b) { return a + b; }' "$5" && grep -q 'gh pr create --repo example-org/sandbox --base feature --head claude/ci-autofix/feature-42' "$5"; }
not_pushed()  { [[ "$1" == "$3" && -z "$2" ]] && grep -q '^pushed=false' "$6"; }
pushed_direct() { [[ "$1" == "$4" ]] && grep -q '^pushed=true' "$6"; }

push_case "pr mode opens a pull request carrying the diagnosis, the verdict and the marker" 0 pr APPROVE true false pr_opened
push_case "a refused pull request hands off with the diff and never falls back to a direct push" 1 pr APPROVE true true pr_refused
push_case "direct mode refuses without the second opinion's approval" 1 direct REJECT true false not_pushed
push_case "direct mode refuses when verification could not run the failing test" 1 direct APPROVE false false not_pushed
push_case "direct mode pushes with both gates green" 0 direct APPROVE true false pushed_direct
push_case "an unknown push_mode pushes nothing" 1 sideways APPROVE true false not_pushed

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
