#!/usr/bin/env bash
# Decides whether this failure is one we should try to fix, and which attempt it is.
# Writes proceed / skip_reason / attempt / branch / protected / pr_number / base_ref to GITHUB_OUTPUT.
set -euo pipefail

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
stop() { out proceed false; out skip_reason "$1"; echo "SKIP: $1"; exit 0; }

out branch "$BRANCH"

# 0. Is there anything to run Claude with? Checking here costs one runner second
#    and says plainly what is wrong, instead of spending a whole fix job to reach
#    a credential error and then filing a handoff that guesses at three causes.
if [[ "${HAS_CLAUDE_CREDENTIAL:-true}" != "true" ]]; then
  stop "Neither \`CLAUDE_CODE_OAUTH_TOKEN\` nor \`ANTHROPIC_API_KEY\` is set for this repo, so there is nothing to diagnose the failure with. On Obelyth these are org secrets; on a personal repo each one has to be set individually. Note that \`gh secret set\` reads the value from stdin unless you pass \`--body\`, so a non-interactive run can store an empty secret that still shows up in \`gh secret list\`."
fi

# 1. Branch patterns we never touch. Checkpoints, the orphan graphify context
#    branch, merge-queue temporaries, and our own fix branches.
IFS=',' read -ra patterns <<< "$SKIP_BRANCHES"
for p in "${patterns[@]}"; do
  p="$(printf '%s' "$p" | xargs)"
  [[ -z "$p" ]] && continue
  # shellcheck disable=SC2053
  if [[ "$BRANCH" == $p ]]; then
    stop "Branch \`$BRANCH\` matches the skip pattern \`$p\`."
  fi
done

if [[ "$SKIP_DEPENDABOT" == "true" && "$BRANCH" == dependabot/* ]]; then
  stop "Branch \`$BRANCH\` is a dependabot branch and skip_dependabot is on."
fi

# 2. Is the branch one we are allowed to push to directly?
protected=false
IFS=',' read -ra prot <<< "$PROTECTED_BRANCHES"
for p in "${prot[@]}"; do
  p="$(printf '%s' "$p" | xargs)"
  [[ "$BRANCH" == "$p" ]] && protected=true
done
out protected "$protected"

# 2b. Has the branch already moved past the commit that failed?
#
#     A run can sit queued while someone pushes a fix, or while an earlier
#     attempt lands one. By the time it starts, the failure it was called about
#     may not exist any more - and diagnosing it means reading a CI log for one
#     commit against a working tree at another, which is how you get a "fix" for
#     a problem that is already gone.
head_now="$(git rev-parse HEAD)"
if [[ -n "${FAILED_SHA:-}" && "$FAILED_SHA" != "$head_now" ]]; then
  stop "The branch moved on. CI failed at \`${FAILED_SHA:0:8}\` but \`$BRANCH\` is now at \`${head_now:0:8}\`, so that failure is already history."
fi

# 2c. Is a fix for this exact failure already waiting for review? In pull
#     request mode the failing branch never moves, so this is the check that
#     stops a second workflow_run event for the same push - one per watched
#     workflow that failed - opening a second pull request for it. The marker
#     is written into every fix PR's body by push-fix.sh.
fix_prs='[]'
if [[ -n "${FAILED_SHA:-}" ]]; then
  marker="<!-- ci-autofix-fix-for:${BRANCH}@${FAILED_SHA} -->"
  fix_prs="$(gh pr list --repo "$REPO" --state all --limit 100 --json number,state,body 2>/dev/null \
    | jq -c --arg m "$marker" '[.[] | select((.body // "") | contains($m))]' 2>/dev/null || echo '[]')"
  open_fix="$(jq -r '[.[] | select(.state == "OPEN")] | .[0].number // empty' <<< "$fix_prs")"
  if [[ -n "$open_fix" ]]; then
    stop "A fix for this failure is already waiting for review in #${open_fix}."
  fi
fi

# 3. Which attempt is this? Count auto-fix commits sitting consecutively at the
#    tip of the branch, or fix pull requests already made for this commit,
#    whichever is more. A human commit on top resets the commit count to zero,
#    so a branch someone is actively working on always gets a fresh budget.
n=0
for sha in $(git rev-list -n 25 HEAD); do
  if git log -1 --format='%B' "$sha" | grep -q '^CI-Autofix-Attempt:'; then
    n=$((n + 1))
  else
    break
  fi
done
pr_attempts="$(jq 'length' <<< "$fix_prs")"
(( pr_attempts > n )) && n=$pr_attempts
attempt=$((n + 1))
out attempt "$attempt"

if (( attempt > MAX_ATTEMPTS )); then
  stop "Already made $n consecutive auto-fix commits on \`$BRANCH\` (limit $MAX_ATTEMPTS). Handing this to a human rather than guessing again."
fi

# 4. Is there a pull request open for this branch? Used for where to comment,
#    and for which branch this one is measured against: the diagnosis needs to
#    know what "this branch's own diff" means.
pr=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open \
      --json number --jq '.[0].number // empty' 2>/dev/null || true)
out pr_number "${pr:-}"

base_ref=""
if [[ -n "$pr" ]]; then
  base_ref="$(gh pr view "$pr" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
fi
if [[ -z "$base_ref" ]]; then
  base_ref="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
fi
out base_ref "${base_ref:-}"

out proceed true
out skip_reason ""
echo "Proceeding. branch=$BRANCH attempt=$attempt protected=$protected pr=${pr:-none} base=${base_ref:-unknown}"
