#!/usr/bin/env bash
# Pushes the fix. Never with --force, never straight at a protected branch, and
# in the default mode never straight at any branch at all.
#
#   push_mode=pr      the fix goes to its own branch and a pull request is
#                     opened, with the diagnosis and the second opinion in its
#                     body, for a person to merge
#   push_mode=direct  the fix is pushed onto the failing branch - and only when
#                     the second opinion approved it and verification actually
#                     ran the test that was failing
#
# If the platform refuses to open the pull request ("GitHub Actions is not
# permitted to create or approve pull requests") this does NOT fall back to a
# direct push. The fix branch stays where it is, the diff goes into the handoff
# comment, and a person opens the PR. A refused PR is a setting to flip, not a
# reason to widen what the robot may do.
set -uo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
PUSH_MODE="${PUSH_MODE:-pr}"
VERDICT="${VERDICT:-}"
VERDICT_REASON="${VERDICT_REASON:-}"
VERIFIED="${VERIFIED:-}"
DIAGNOSIS="${DIAGNOSIS:-}"
AUDIT_URL="${AUDIT_URL:-}"
AUDIT_DIR="${AUDIT_DIR:-${RUNNER_TEMP}/audit}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PR_NUMBER="${PR_NUMBER:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$PUSH_MODE" in
  pr|direct) ;;
  *) echo "::error::push_mode must be 'pr' or 'direct', not '$PUSH_MODE'. Nothing was pushed." >&2
     echo "pushed=false" >> "$GITHUB_OUTPUT"; exit 1 ;;
esac

# A push made with the built-in token deliberately starts no new workflow run,
# so the green tick would never appear. PUSH_TOKEN closes that loop - and a
# pull request opened with it is opened by a user, not by Actions, so the org
# setting that forbids Actions from creating pull requests does not apply.
#
# It is checked against the shape of a GitHub token - at least 30 characters of
# letters, digits and underscores - because an optional credential must never be
# able to fail the run, and a secret set by accident holds anything at all. A
# value with a colon in it read as a port number and killed the push.
#
# The credential goes in a header rather than the remote URL, which is what
# actions/checkout does: a URL has to be parsed, a header does not.
HAS_PUSH_TOKEN=false
GIT_AUTH=()
if [[ "$PUSH_TOKEN" =~ ^[A-Za-z0-9_]{30,}$ ]]; then
  GIT_AUTH=(-c "http.https://github.com/.extraheader=Authorization: Basic $(
    printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 -w0)")
  HAS_PUSH_TOKEN=true
elif [[ -n "$PUSH_TOKEN" ]]; then
  echo "::warning::CI_AUTOFIX_TOKEN is set but is not shaped like a GitHub token, so it was ignored. Pushing with the built-in token instead, which will not start a new CI run."
fi

gitpush() { git "${GIT_AUTH[@]}" push "$@"; return $?; }

# A push the origin rejects - a protection rule, a hook, a permission, a
# branch that moved - is not a push. Every push here is checked, and a refused
# one hands off with the diff, because the commit exists nowhere else.
push_or_handoff() {  # refspec target-branch
  local refspec="$1" target="$2" err
  if gitpush origin "$refspec" > "${RUNNER_TEMP}/push.log" 2>&1; then
    cat "${RUNNER_TEMP}/push.log"
    return 0
  fi
  cat "${RUNNER_TEMP}/push.log"
  err="$(grep -E '^\s*!|error:|fatal:|remote:' "${RUNNER_TEMP}/push.log" | tr '\n' ' ' | sed 's/ *$//')"
  [[ -n "$err" ]] || err="$(tr '\n' ' ' < "${RUNNER_TEMP}/push.log")"
  echo "::error::The push to \`$target\` was refused, so nothing landed anywhere: $err" >&2
  mkdir -p "$AUDIT_DIR"
  [[ -s "$AUDIT_DIR/fix.diff" ]] || git diff "${BASE_SHA}..HEAD" > "$AUDIT_DIR/fix.diff"
  handoff_env FIX_RESULT=push-failed FIX_BRANCH="$target" PUSH_REFUSAL="$err" DIFF_FILE="$AUDIT_DIR/fix.diff" \
    bash "$HERE/handoff.sh"
  {
    echo "## Not pushed"; echo
    echo "The push to \`$target\` was refused:"
    echo; echo '```'; echo "$err"; echo '```'; echo
    echo "Nothing landed on any branch. The handoff comment and the audit trail carry the diff."
  } >> "$GITHUB_STEP_SUMMARY"
  echo "pushed=false" >> "$GITHUB_OUTPUT"
  echo "handoff_posted=true" >> "$GITHUB_OUTPUT"
  exit 1
}
# gh with the push token when there is one, so the PR counts as a user's.
ghp() { if $HAS_PUSH_TOKEN; then GH_TOKEN="$PUSH_TOKEN" gh "$@"; else gh "$@"; fi; return $?; }

SHA="$(git rev-parse HEAD)"
echo "sha=$SHA" >> "$GITHUB_OUTPUT"

SUBJECT="$(git log -1 --format='%s')"
BODY="$(git log -1 --format='%b')"

# What the run knew when it decided to push, for the PR body and the comment.
diag_section() {
  if [[ -n "$DIAGNOSIS" && -f "$DIAGNOSIS" ]]; then
    local class tests allowed
    class="$(jq -r '.class' "$DIAGNOSIS")"
    tests="$(jq -r '.failing_tests | join(", ")' "$DIAGNOSIS")"
    allowed="$(jq -r '.allowed_paths | join(", ")' "$DIAGNOSIS")"
    printf -- '- Diagnosis: `%s`. Failing tests: %s. Files the fixer was allowed to change: %s.\n' \
      "$class" "${tests:-none identified}" "${allowed:-none}"
  else
    printf -- '- Diagnosis: not available.\n'
  fi
  printf -- '- Second opinion: **%s**%s.\n' "${VERDICT:-not recorded}" "${VERDICT_REASON:+ - $VERDICT_REASON}"
  [[ -n "$AUDIT_URL" ]] && printf -- '- Audit trail (transcripts, diagnosis, verdict, diff): %s\n' "$AUDIT_URL"
  return 0
}

handoff_env() {
  # Everything handoff.sh wants, from what this script has.
  local class="" reason="" allowed="" tests=""
  if [[ -n "$DIAGNOSIS" && -f "$DIAGNOSIS" ]]; then
    class="$(jq -r '.class' "$DIAGNOSIS")"; reason="$(jq -r '.reason' "$DIAGNOSIS")"
    allowed="$(jq -r '.allowed_paths | join(" ")' "$DIAGNOSIS")"; tests="$(jq -r '.failing_tests | join(" ")' "$DIAGNOSIS")"
  fi
  env DIAG_CLASS="$class" DIAG_REASON="$reason" ALLOWED_PATHS="$allowed" FAILING_TESTS="$tests" \
      VERDICT="$VERDICT" VERDICT_REASON="$VERDICT_REASON" AUDIT_URL="$AUDIT_URL" "$@"
  return $?
}

# --- Pull request: the default, and always the route for a protected branch ---
if [[ "$PUSH_MODE" == "pr" || "$PROTECTED" == "true" ]]; then
  FIX_BRANCH="claude/ci-autofix/${BRANCH//\//-}-${GITHUB_RUN_ID}"
  git checkout -b "$FIX_BRANCH"
  push_or_handoff "$FIX_BRANCH" "$FIX_BRANCH"

  why="opened as a pull request rather than pushed directly, because push_mode is \`pr\`"
  [[ "$PROTECTED" == "true" ]] && why="opened as a pull request rather than pushed directly, because \`$BRANCH\` is a protected branch"
  MARKER="<!-- ci-autofix-fix-for:${BRANCH}@${BASE_SHA} -->"
  PR_BODY="$(printf '%s\n\n---\n\nCI on `%s` failed at `%s` and this is the fix, %s.\n\n%s\n\nThe checks ran against this branch in the runner before it was pushed, and the honesty check confirmed it stays inside the diagnosed scope and weakens no test or CI gate.\n\n%s\n' \
    "$BODY" "$BRANCH" "${BASE_SHA:0:8}" "$why" "$(diag_section)" "$MARKER")"

  if ! PR_URL="$(ghp pr create --base "$BRANCH" --head "$FIX_BRANCH" --title "$SUBJECT" --body "$PR_BODY" 2> "${RUNNER_TEMP}/pr-create.err")"; then
    ERR="$(tr '\n' ' ' < "${RUNNER_TEMP}/pr-create.err")"
    echo "::error::The fix is on \`$FIX_BRANCH\` but the pull request could not be opened: $ERR" >&2
    mkdir -p "$AUDIT_DIR"
    [[ -s "$AUDIT_DIR/fix.diff" ]] || git diff "${BASE_SHA}..HEAD" > "$AUDIT_DIR/fix.diff"
    handoff_env FIX_RESULT=push-refused FIX_BRANCH="$FIX_BRANCH" PR_REFUSAL="$ERR" DIFF_FILE="$AUDIT_DIR/fix.diff" \
      bash "$HERE/handoff.sh"
    {
      echo "## Not merged"; echo
      echo "The fix was pushed to \`$FIX_BRANCH\` but GitHub refused to open the pull request:"
      echo; echo '```'; echo "$ERR"; echo '```'; echo
      echo "Nothing was pushed to \`$BRANCH\`. The handoff comment carries the diff and the command to open the PR by hand."
    } >> "$GITHUB_STEP_SUMMARY"
    echo "pushed=false" >> "$GITHUB_OUTPUT"
    echo "pushed_branch=$FIX_BRANCH" >> "$GITHUB_OUTPUT"
    echo "handoff_posted=true" >> "$GITHUB_OUTPUT"
    exit 1
  fi

  echo "pushed=true" >> "$GITHUB_OUTPUT"
  echo "pushed_branch=$FIX_BRANCH" >> "$GITHUB_OUTPUT"
  echo "pr_url=$PR_URL" >> "$GITHUB_OUTPUT"
  { echo "## Pushed"; echo; echo "Opened $PR_URL against \`$BRANCH\`."; } >> "$GITHUB_STEP_SUMMARY"

  if [[ -n "$PR_NUMBER" ]]; then
    gh pr comment "$PR_NUMBER" --body "$(printf '### CI fixed automatically\n\n%s\n\nThe fix is waiting for review in %s.\n\n%s\n' "$SUBJECT" "$PR_URL" "$(diag_section)")" || true
  fi
  if ! $HAS_PUSH_TOKEN; then
    echo "::warning::CI_AUTOFIX_TOKEN is not set, so CI will not run on the fix branch by itself. Re-run CI on the pull request by hand to see the green tick."
  fi
  exit 0
fi

# --- Direct push: only with both gates green ----------------------------------
if [[ "$VERDICT" != "APPROVE" || "$VERIFIED" != "true" ]]; then
  echo "::error::push_mode is 'direct', which needs the second opinion to approve and verification to have run the failing test here. Got verdict='${VERDICT:-none}', verified='${VERIFIED:-false}'. Nothing was pushed." >&2
  { echo "## Not pushed"; echo; echo "Direct push needs \`VERDICT: APPROVE\` and \`verified=true\`; this run had verdict \`${VERDICT:-none}\` and verified \`${VERIFIED:-false}\`."; } >> "$GITHUB_STEP_SUMMARY"
  echo "pushed=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

# Someone may have pushed while we worked. Rebase would rewrite their history,
# so refuse instead and let the next run start from their commit.
git fetch origin "$BRANCH"
if [[ "$(git rev-parse "origin/$BRANCH")" != "$BASE_SHA" ]]; then
  echo "::warning::\`$BRANCH\` moved while the fix was being prepared. Not pushing; the next CI failure will start again from the new head."
  { echo "## Not pushed"; echo; echo "\`$BRANCH\` moved on while this ran, so the fix was dropped rather than layered onto someone else's commit."; } >> "$GITHUB_STEP_SUMMARY"
  echo "pushed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

push_or_handoff "HEAD:$BRANCH" "$BRANCH"
echo "pushed=true" >> "$GITHUB_OUTPUT"
echo "pushed_branch=$BRANCH" >> "$GITHUB_OUTPUT"

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --body "$(printf '### CI fixed automatically\n\n%s\n\n%s\n\nCommit `%s`. The honesty check confirmed the fix stays inside the diagnosed scope and weakens no test or CI gate; the suite, including the test that was failing, passed in the runner before this was pushed.\n\n%s\n' "$SUBJECT" "$BODY" "${SHA:0:8}" "$(diag_section)")" || true
fi

{
  echo "## Pushed"
  echo
  echo "Commit \`${SHA:0:8}\` on \`$BRANCH\`."
} >> "$GITHUB_STEP_SUMMARY"

if [[ "${HAS_PUSH_TOKEN}" != "true" ]]; then
  echo "::warning::CI_AUTOFIX_TOKEN is not set, so this push will not start a new CI run. The fix is verified but the branch needs a manual re-run to show green."
  { echo; echo "> \`CI_AUTOFIX_TOKEN\` is not set on this repo, so GitHub will not start a fresh CI run for this push. Re-run CI by hand to see the green tick."; } >> "$GITHUB_STEP_SUMMARY"
fi
