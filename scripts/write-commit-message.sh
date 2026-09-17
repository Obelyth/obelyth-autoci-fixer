#!/usr/bin/env bash
# Claude writes the what / why / how. This adds the machine-readable trailers on
# top, including the attempt counter the triage step reads back on the next run.
set -euo pipefail

BODY="$(git log -1 --format=%B)"

# Strip any trailer Claude may have written itself, so we own these lines.
BODY="$(printf '%s' "$BODY" | grep -v '^CI-Autofix-' || true)"
# House rule: commits carry no Co-Authored-By trailer. Strip it rather than
# trusting the prompt, since a model that has seen a million of them will add
# one back eventually.
BODY="$(printf '%s' "$BODY" | grep -viE '^(Co-Authored-By|Signed-off-by):' || true)"

FILES_CHANGED="$(git diff --name-only "${BASE_SHA}..HEAD" | sed 's/^/  /')"

DIAG_LINE="not diagnosed"; DIAG_CLASS="unknown"
if [[ -n "${DIAGNOSIS:-}" && -f "$DIAGNOSIS" ]]; then
  DIAG_LINE="$(jq -r '"\(.class) - \(.reason)"' "$DIAGNOSIS")"
  DIAG_CLASS="$(jq -r '.class // "unknown"' "$DIAGNOSIS")"
fi

NEW_MESSAGE="$(cat <<EOF
${BODY}

Diagnosed as: ${DIAG_LINE}

Files changed:
${FILES_CHANGED}

Verified in the runner: ${VERIFY_SUMMARY:-not verified}
Second opinion: ${VERDICT:-none}${REVIEWER_MODEL:+ (${REVIEWER_MODEL})}

CI-Autofix-Attempt: ${ATTEMPT}/${MAX_ATTEMPTS}
CI-Autofix-Failed-Run: ${FAILED_RUN_URL}
CI-Autofix-Base: ${BASE_SHA}
CI-Autofix-Class: ${DIAG_CLASS}
CI-Autofix-Second-Opinion: ${VERDICT:-none}
EOF
)"

git commit --amend -m "$NEW_MESSAGE" --no-verify >/dev/null
echo "Commit message finalised:"
git log -1 --format='%s'
