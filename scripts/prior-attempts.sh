#!/usr/bin/env bash
# Gathers what earlier attempts on this branch already tried.
#
# Claude Code sessions live on the runner's disk, so a later attempt lands on a
# fresh machine with no memory of the last one. Without this, attempt two starts
# blind and often walks straight back into attempt one's dead end. The findings
# are already written down in three places - the commit message of an attempt
# that pushed, the body of a fix pull request one opened, and the handoff report
# of one that did not - so this collects all three.
set -euo pipefail

OUT="${RUNNER_TEMP}/prior-attempts.md"
: > "$OUT"

(( ATTEMPT <= 1 )) && { echo "path=" >> "$GITHUB_OUTPUT"; echo "First attempt; nothing to carry forward."; exit 0; }

{
  echo "# What earlier attempts on this branch already tried"
  echo
  echo "This is attempt ${ATTEMPT}. Read this before you start."
  echo "Do not repeat an approach that is recorded here as having failed."
  echo
} >> "$OUT"

# --- attempts that pushed: their reasoning is in the commit message ----------
found=false
for sha in $(git rev-list -n 10 HEAD); do
  git log -1 --format='%B' "$sha" | grep -q '^CI-Autofix-Attempt:' || break
  {
    echo "## Auto-fix commit ${sha:0:8} (pushed, but CI stayed red)"
    echo
    echo '```'
    git log -1 --format='%B' "$sha"
    echo '```'
    echo
    echo "It changed:"
    git show --stat --format='' "$sha" | sed 's/^/    /'
    echo
  } >> "$OUT"
  found=true
done

# --- attempts that opened a pull request: the body carries the diagnosis -----
fix_prs="$(gh pr list --state all --limit 100 --json number,state,title,body,url 2>/dev/null \
  | jq -c --arg m "<!-- ci-autofix-fix-for:${BRANCH}@" '[.[] | select((.body // "") | contains($m))]' 2>/dev/null || echo '[]')"
if [[ "$(jq 'length' <<< "$fix_prs")" -gt 0 ]]; then
  jq -r '.[] | "## Fix pull request #\(.number) (\(.state)): \(.title)\n\n\(.url)\n\n```\n\(.body | split("\n")[:40] | join("\n"))\n```\n"' <<< "$fix_prs" >> "$OUT"
  found=true
fi

# --- attempts that were blocked: the handoff report says why -----------------
report=""
if [[ -n "${PR_NUMBER:-}" ]]; then
  report="$(gh pr view "$PR_NUMBER" --json comments \
    --jq '[.comments[] | select(.body | test("CI Auto-Fix stopped|could not fix it"))] | last | .body // empty' 2>/dev/null || true)"
else
  marker="<!-- ci-autofix-handoff:${BRANCH} -->"
  num="$(gh issue list --state open --limit 100 --json number,body 2>/dev/null \
    | jq -r --arg m "$marker" '[.[] | select(.body | contains($m))] | .[0].number // empty' 2>/dev/null || true)"
  [[ -n "$num" ]] && report="$(gh issue view "$num" --json body --jq '.body' 2>/dev/null || true)"
fi

if [[ -n "$report" ]]; then
  {
    echo "## The last attempt was stopped before it could push"
    echo
    echo '```'
    printf '%s\n' "$report" | head -40
    echo '```'
    echo
  } >> "$OUT"
  found=true
fi

if ! $found; then
  echo "_No record of what earlier attempts tried._" >> "$OUT"
fi

echo "path=$OUT" >> "$GITHUB_OUTPUT"
echo "Carrying forward $(wc -c < "$OUT") bytes from earlier attempts."
