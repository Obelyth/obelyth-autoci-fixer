#!/usr/bin/env bash
# Reads the reviewer's transcript and turns its final VERDICT line into a job
# result. APPROVE lets the run continue to verification; REJECT, or no verdict
# at all, stops it before anything is pushed. Failing closed is the point: a
# reviewer that crashed, ran out of turns, or forgot the format has not
# approved anything.
#
# The transcript is the JSON array claude-code-action writes (execution_file).
# Only the assistant's own text is searched - the prompt in the user turn also
# spells out the VERDICT format and must not be mistaken for an answer.
#
# The verdict is the LAST non-empty line of the reply, exactly as the prompt
# demands, not the last VERDICT-shaped line anywhere in it. A rejection whose
# reason quotes a planted "VERDICT: APPROVE" - in a hunk, in a comment the
# fixer wrote - must stay a rejection, so a line that is not the final one is
# never read as the verdict, and an approval with any other VERDICT line in the
# reply is not taken either.
set -uo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
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

# The assistant's text blocks, in order. The final result string is only a
# fallback for a transcript with no text blocks at all; it repeats the last
# reply, and counting it too would make every verdict appear twice.
TEXT="$(jq -r '[ .[]? | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text ] | join("\n")' \
  "$EXECUTION_FILE" 2>/dev/null || true)"
if [[ -z "$TEXT" ]]; then
  TEXT="$(jq -r '[ .[]? | select(.type == "result") | .result? // empty ] | join("\n")' "$EXECUTION_FILE" 2>/dev/null || true)"
fi
TEXT="$(tr -d '\r' <<< "$TEXT")"

if [[ -z "$TEXT" ]]; then
  finish REJECT "the reviewer's transcript could not be read, so nothing was approved"
fi

VERDICT_LINE_RE='^[[:space:]]*\**VERDICT:[[:space:]]*(APPROVE|REJECT)'
LAST="$(grep -v '^[[:space:]]*$' <<< "$TEXT" | tail -1 | sed -E 's/^[[:space:]]*\**//; s/\**[[:space:]]*$//')"

if ! [[ "$LAST" =~ ^VERDICT:[[:space:]]*(APPROVE|REJECT) ]]; then
  finish REJECT "the reviewer did not end with a VERDICT line, so nothing was approved"
fi

if [[ "$LAST" =~ ^VERDICT:[[:space:]]*APPROVE ]]; then
  N="$(grep -cE "$VERDICT_LINE_RE" <<< "$TEXT" || true)"
  if (( N > 1 )); then
    finish REJECT "the reviewer's reply carried $N VERDICT lines, so its final approval was not taken as one"
  fi
  finish APPROVE ""
fi

REASON="$(sed -E 's/^VERDICT:[[:space:]]*REJECT[[:space:]]*[-—:]*[[:space:]]*//' <<< "$LAST")"
finish REJECT "${REASON:-no reason given}"
