#!/usr/bin/env bash
# Reads the reviewer's transcript and turns its last VERDICT line into a job
# result. APPROVE lets the run continue to verification; REJECT, or no verdict
# at all, stops it before anything is pushed. Failing closed is the point: a
# reviewer that crashed, ran out of turns, or forgot the format has not
# approved anything.
#
# The transcript is the JSON array claude-code-action writes (execution_file).
# Only the assistant's own text is searched - the prompt in the user turn also
# spells out the VERDICT format and must not be mistaken for an answer.
set -uo pipefail

EXECUTION_FILE="${EXECUTION_FILE:-}"
OUT="${VERDICT_OUT:-${RUNNER_TEMP}/verdict.txt}"
REVIEWER_MODEL="${REVIEWER_MODEL:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

finish() {  # verdict, reason
  local verdict="$1" reason="$2"
  {
    echo "VERDICT: $verdict"
    [[ -n "$reason" ]] && echo "REASON: $reason"
    [[ -n "$REVIEWER_MODEL" ]] && echo "MODEL: $REVIEWER_MODEL"
  } > "$OUT"
  {
    echo "verdict=$verdict"
    echo "reason=$reason"
    echo "path=$OUT"
  } >> "$GITHUB_OUTPUT"
  {
    echo "## Second opinion"
    echo
    if [[ "$verdict" == "APPROVE" ]]; then
      echo "**Approved** by an independent read-only review${REVIEWER_MODEL:+ ($REVIEWER_MODEL)}."
    else
      echo "**Rejected** by an independent read-only review${REVIEWER_MODEL:+ ($REVIEWER_MODEL)}: $reason"
      echo
      echo "Nothing was pushed."
    fi
    echo
  } >> "$GITHUB_STEP_SUMMARY"
  if [[ "$verdict" == "APPROVE" ]]; then
    echo "Second opinion: APPROVE"
    exit 0
  fi
  echo "::error::Second opinion: REJECT - $reason"
  exit 1
}

if [[ -z "$EXECUTION_FILE" || ! -s "$EXECUTION_FILE" ]]; then
  finish REJECT "the reviewer produced no transcript, so nothing was approved"
fi

# Assistant text blocks in order, then the final result string if there is one.
TEXT="$(jq -r '
  [ .[]? | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text ]
  + [ .[]? | select(.type == "result") | .result? // empty ]
  | join("\n")' "$EXECUTION_FILE" 2>/dev/null || true)"

if [[ -z "$TEXT" ]]; then
  finish REJECT "the reviewer's transcript could not be read, so nothing was approved"
fi

LINE="$(grep -E '^[[:space:]]*\**VERDICT:[[:space:]]*(APPROVE|REJECT)' <<< "$TEXT" | tail -1 | sed -E 's/^[[:space:]]*\**//; s/\**[[:space:]]*$//')"

if [[ -z "$LINE" ]]; then
  finish REJECT "the reviewer did not end with a VERDICT line, so nothing was approved"
fi

if [[ "$LINE" =~ ^VERDICT:[[:space:]]*APPROVE ]]; then
  finish APPROVE ""
fi

REASON="$(sed -E 's/^VERDICT:[[:space:]]*REJECT[[:space:]]*[-—:]*[[:space:]]*//' <<< "$LINE")"
finish REJECT "${REASON:-no reason given}"
