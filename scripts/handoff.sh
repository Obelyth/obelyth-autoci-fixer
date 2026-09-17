#!/usr/bin/env bash
# Called when the run stops without pushing - or before it starts, when the
# diagnosis says the failure is not this branch's to fix. Says plainly what was
# found, what stopped it, and that nothing was pushed - then gets out of the way.
#
# Context arrives in the environment and every piece is optional:
#   FIX_RESULT     failure | cancelled | env-data | unlinked | rejected | push-refused
#   DIAG_CLASS, DIAG_REASON, FAILING_TESTS, ALLOWED_PATHS   from the diagnosis
#   VERDICT, VERDICT_REASON                                 the second opinion
#   COULD_NOT_RUN                                           from verification
#   FIX_BRANCH, PR_REFUSAL, DIFF_FILE                       a refused pull request
#   AUDIT_URL                                               the uploaded audit trail
set -uo pipefail

GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"; export GH_REPO
FIX_RESULT="${FIX_RESULT:-failure}"
ATTEMPT="${ATTEMPT:-1}"; MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
FAILED_RUN_URL="${FAILED_RUN_URL:-}"
FIX_RUN_URL="${FIX_RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}}"
PR_NUMBER="${PR_NUMBER:-}"
DIFF_CAP=40000   # GitHub comments stop at 65536 characters

case "$FIX_RESULT" in
  env-data)     headline="CI Auto-Fix stopped: this failure is not caused by this branch" ;;
  unlinked)     headline="CI Auto-Fix stopped: this failure could not be linked to this branch" ;;
  rejected)     headline="CI Auto-Fix stopped: the second opinion rejected the fix" ;;
  push-refused) headline="CI Auto-Fix has a fix, but could not open the pull request" ;;
  cancelled)    headline="CI Auto-Fix was cancelled" ;;
  failure)      headline="CI Auto-Fix stopped without pushing" ;;
  *)            headline="CI Auto-Fix did not complete" ;;
esac

BODY="### ${headline}

Attempt ${ATTEMPT} of ${MAX_ATTEMPTS} on \`${BRANCH}\`.

- Failing CI run: ${FAILED_RUN_URL}
- Auto-fix run: ${FIX_RUN_URL}"
[[ -n "${AUDIT_URL:-}" ]] && BODY+="
- Audit trail (transcripts, diagnosis, verdict, diff): ${AUDIT_URL}"

if [[ -n "${DIAG_CLASS:-}" ]]; then
  BODY+="

**Diagnosis: \`${DIAG_CLASS}\`.** ${DIAG_REASON:-}"
  [[ -n "${FAILING_TESTS:-}" ]] && BODY+="
- Failing tests: $(sed 's/ /, /g' <<< "$FAILING_TESTS")"
  [[ -n "${ALLOWED_PATHS:-}" ]] && BODY+="
- Files the fixer was allowed to change: $(sed 's/ /, /g' <<< "$ALLOWED_PATHS")"
fi

case "$FIX_RESULT" in
  env-data)
    BODY+="

No model was run and nothing was pushed. A failure caused by data or a checkout this runner cannot see is an environment failure, and the fix - if there is one - lives outside this branch. Check the data, the token, or the job that provides it." ;;
  unlinked)
    BODY+="

No model was run and nothing was pushed. When the diff cannot be connected to the failure, the honest move is to stop rather than edit whatever the log happens to mention. If the failure is flaky, re-run CI; if it is real, it belongs to an earlier change." ;;
esac

[[ -n "${VERDICT:-}" ]] && BODY+="

**Second opinion: ${VERDICT}.**${VERDICT_REASON:+ $VERDICT_REASON}"

[[ -n "${COULD_NOT_RUN:-}" ]] && BODY+="

**Verification could not run the failing test here:** ${COULD_NOT_RUN}. The suite passed, but a pass that never exercised the failing test proves nothing, so nothing was pushed."

if [[ "$FIX_RESULT" == "push-refused" ]]; then
  BODY+="

The fix is on \`${FIX_BRANCH:-}\`. GitHub refused to open the pull request:

\`\`\`
${PR_REFUSAL:-no message}
\`\`\`

This is the repository or organisation setting **Allow GitHub Actions to create and approve pull requests**, or a missing \`CI_AUTOFIX_TOKEN\`. The run did not fall back to pushing at \`${BRANCH}\`. Open the pull request by hand:

\`\`\`
gh pr create --repo ${GH_REPO} --base ${BRANCH} --head ${FIX_BRANCH:-}
\`\`\`"
  if [[ -n "${DIFF_FILE:-}" && -s "$DIFF_FILE" ]]; then
    DIFF="$(head -c "$DIFF_CAP" "$DIFF_FILE")"
    (( $(wc -c < "$DIFF_FILE") > DIFF_CAP )) && DIFF+=$'\n... (truncated; the full diff is on the branch and in the audit trail)'
    BODY+="

<details><summary>The diff</summary>

\`\`\`diff
${DIFF}
\`\`\`

</details>"
  fi
fi

if [[ "$FIX_RESULT" == "failure" || "$FIX_RESULT" == "cancelled" ]]; then
  BODY+="

Nothing was pushed. The usual reasons, in order of likelihood:

1. The honesty check blocked the change: it left the diagnosed scope, grew past the size caps, or would have made CI pass by weakening a test or a CI gate.
2. The second opinion rejected the fix, or the checks still failed in the runner after it.
3. The cause is not something a code change in this repo can fix, for example a missing secret, an expired token, or an outage at a service CI depends on.

The auto-fix run above says which."
fi

BODY+="

This one needs a person."

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --body "$BODY"
  echo "Commented on PR #${PR_NUMBER}."
  echo "posted=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# No pull request, so use an issue - but only one per branch, kept up to date.
MARKER="<!-- ci-autofix-handoff:${BRANCH} -->"
# GitHub's search tokenises, so `in:body ci-autofix-handoff:feature/foo` also
# matches an issue for `feature/foo-bar`. Match the marker exactly instead.
EXISTING="$(gh issue list --state open --limit 100 --json number,body 2>/dev/null \
  | jq -r --arg m "$MARKER" '[.[] | select(.body | contains($m))] | .[0].number // empty' 2>/dev/null || true)"

if [[ -n "$EXISTING" ]]; then
  gh issue comment "$EXISTING" --body "$BODY"
  echo "Commented on existing issue #${EXISTING}."
else
  gh issue create \
    --title "CI is red on \`${BRANCH}\` and auto-fix could not fix it" \
    --body "${BODY}

${MARKER}"
  echo "Opened a handoff issue."
fi
echo "posted=true" >> "${GITHUB_OUTPUT:-/dev/null}"
