<div align="center">

<img src="assets/banner.svg" alt="CI Auto-Fix — fixes failing CI, honestly" width="100%">

<br>

**When CI goes red, this works out why, fixes the cause, and pushes one commit that explains itself.**

It will not delete a test, skip a test, relax a CI gate, or force push to get there —
and that isn't a promise in a prompt, it's a guard that reads the diff and throws the
whole change away if it finds one.

[![CI](https://github.com/Obelyth/obelyth-autoci-fixer/actions/workflows/ci.yml/badge.svg)](https://github.com/Obelyth/obelyth-autoci-fixer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Powered by Claude](https://img.shields.io/badge/powered%20by-Claude-d97757)](https://claude.com/claude-code)

</div>

---

## What it actually does

A branch got pushed with a subtle regression: a non-global regex, so `match()`
returned only the first unit and `parseDuration('1h30m')` gave `3600` instead of
`5400`. Four of seven tests failed. Single-unit parsing still passed, so the test
names didn't give the answer away.

Nobody was watching. Eleven minutes later this was on the branch:

```
fix: parse every unit in a compound duration again

What was broken:
  npm test failed with 4 of 7 tests failing in test/duration.test.js.
  parseDuration returned only the first unit of a compound duration:
  '1h30m' gave 3600 instead of 5400, and '2d4h15m' gave 172800 instead
  of 188100.

Why it broke:
  The refactor in 0a00b09 swapped matchAll for match and dropped the g
  flag from the PART regex. A non-global String.prototype.match returns
  only the first match, so wrapping it as [parts] gave the loop exactly
  one <amount><unit> pair and every later pair was silently discarded.
  Single-unit inputs still worked, which is why three tests kept passing.

How this fixes it:
  PART gets its g flag back and parseDuration goes back to spreading
  normalised.matchAll(PART), so the loop iterates over every pair and
  sums them all. The empty check becomes parts.length === 0, which is
  the matchAll equivalent of the previous null check, so unparseable
  input still throws SyntaxError.
```

Four lines changed, in the source file only. No test was touched. It cost about
**40 cents**.

It doesn't care who pushed. A human, an agent, a cloud session — same treatment.

---

## The part that matters

Any model asked to make CI green can make CI green. Deleting the failing test
works. So does `continue-on-error: true`. The reason this is safe to leave running
unattended is that those routes are closed by
[`scripts/honesty-guard.sh`](scripts/honesty-guard.sh), which reads the diff before
anything is pushed and discards the whole change if it finds:

| Blocked | Why |
|---|---|
| Changing any file the diagnosis did not implicate | The fix is for what failed, not for whatever the log mentions |
| More than 5 files or 150 changed lines (`max_changed_files` / `max_changed_lines`) | A fix that wide is the wrong fix, or several; a person reads it |
| Binary content in the diff | Neither reviewable nor countable against the size cap |
| Deleting a test file or a test case | Fewer tests is not a passing suite |
| `.skip`, `.todo`, `xit`, `@pytest.mark.skip`, `t.Skip`, `#[ignore]`, `@Ignore` | Silencing the check that caught the problem |
| A drop in the number of assertions | Same, one level down |
| `continue-on-error: true`, `if: false`, `\|\| true` in a workflow | Stops a failure from failing the build |
| Removing a step from a workflow | Deleting the check instead of fixing the cause |
| A `test` / `lint` / `typecheck` / `build` script replaced with `true` or `echo` | Hollowing out the gate |
| Touching `lefthook.yml`, `.husky/`, `.pre-commit-config.yaml`, `.githooks/` | Hooks are a gate; changing them is a human decision |
| `--no-verify`, `--force`, `--admin` anywhere | Bypass flags |
| Force push, rebase, or any rewritten history | A fix only ever adds commits |
| Pushing to `main` or any protected branch | Those get a pull request |
| Editing the guard, its tests, the fingerprint, or the playbook | The rules that judge a fix are not the fixer's to change |

There is **no override flag**, and the agent cannot grant itself one. If a fix
genuinely requires removing a test, that is a person's call — the run stops and
says so.

Every row above has a test in [`tests/guard_test.sh`](tests/guard_test.sh) that
makes the move and asserts the guard blocks it. They run on every change to this
repo.

> **Stopping is a good outcome.** The playbook is explicit that a clear
> "here is the cause, here is why I did not fix it" beats a dishonest green.

---

## How a fix happens

```
CI fails
   │
   ├─ Triage ─────── skip checkpoint / merge-queue / dependabot branches and forks
   │                 count auto-fix commits and fix PRs — 3 and it stops
   │                 a human commit on top resets the count
   ├─ Evidence ───── the first error in context, plus the tail. Not the whole log.
   ├─ Diagnose ───── which job and step failed, which test files the log names,
   │                 what this branch changed, and whether the two meet
   │                   code      → fix the source; allowed = implicated + the branch's files
   │                   test      → fix that test only; allowed = the failing test
   │                   env-data  → STOP: a checkout or data this runner cannot see
   │                   unlinked  → STOP: nothing this branch changed is implicated
   │                 (a stop posts a comment and runs no model at all)
   │
   ├─ Scope ──────── the allowed paths become a deny list the fixer runs under
   ├─ Fingerprint ── how many test files, test cases and assertions exist right now
   ├─ Recall ─────── what earlier attempts on this branch already tried
   ├─ Fix ────────── reproduce it, name the cause, fix the cause inside the box
   │                 (no push permission, cannot rewrite history, makes one commit)
   │
   ├─ Seal ───────── the toolkit is hashed before the fixer and checked after it;
   │                 the diagnosis is reloaded from the triage job, not the disk
   ├─ Honesty ────── the diff against the table above, the scope, and the size caps
   ├─ Second opinion  a different model, read-only, told to refute the fix
   │                 VERDICT: APPROVE or VERDICT: REJECT — reject stops the run
   ├─ Verify ─────── re-run the repo's checks in a clean worktree of the commit;
   │                 the failing test must have run here, not skipped, or the
   │                 pass proves nothing and nothing is pushed
   ├─ Audit ──────── both transcripts, diagnosis, verdict, diff → uploaded artifact
   ├─ Push ───────── a pull request by default (`push_mode: pr`); `direct` pushes
   │                 to the branch only with APPROVE and a verified run
   └─ Watch ─────── report how the re-run went
```

If any stage fails, nothing is pushed and a comment explains why — with the
diagnosis, the verdict and a link to the audit artifact — on the pull request if
there is one, otherwise a single issue per branch.

### Why diagnose first

The run that shaped this: a pull request changed `lib/health.ts` and its own
test. A separate job that checks out a private data repository failed in
`tests/hard-router.test.ts` on the *content of a note in that repository*. The
fixer could not read that checkout, said so in its commit message ("Nothing in
this branch touches the router, the parser, or that note"), and rewrote the
router test, the frontmatter test and the parser anyway — 63 turns, $4.59.
Verification then ran the suite, the router test skipped itself for want of the
data, and the run counted that as green.

Now the diagnosis runs before any model does. That failure is `env-data`: the
failing test is not among the branch's files, the job checks out another
repository, and the log names a file that does not exist in this checkout. It
stops with a comment and costs nothing.

### The second opinion

A fresh session on a different model reads the diagnosis, the whole diff and
its `git log --stat` (both rendered for it beforehand), the playbook and the
failing log, with `Read`, `Glob` and `Grep` only — no shell, no editing tools —
and is told to refute the fix. It ends with `VERDICT: APPROVE` or
`VERDICT: REJECT — <why>` as its final line; anything else — no verdict, a
verdict that is not the last line, more than one verdict, no transcript —
counts as reject. The fixer is `claude-opus-5` and the
reviewer `claude-sonnet-5` by default (`fixer_model` / `reviewer_model`): a
reviewer that shares the fixer's weights tends to find the fixer's reasoning
persuasive, and the point of a second opinion is independent error. A read-only
pass on the cheaper model is also a fraction of the cost.

### Where the fix lands

`push_mode: pr` (the default) pushes the fix to `claude/ci-autofix/<branch>-<run>`
and opens a pull request against the failing branch with the diagnosis, the
verdict and the audit link in its body. `push_mode: direct` pushes onto the
branch itself, and only when the verdict is APPROVE and verification ran the
failing test here. Protected branches always get a pull request.

If GitHub refuses to open the pull request — the org or repo setting **Allow
GitHub Actions to create and approve pull requests** is off, and there is no
`CI_AUTOFIX_TOKEN` to open it as a user — the run does **not** fall back to a
direct push. The fix stays on its branch, the handoff comment carries the diff
and the `gh pr create` command, and a person opens it. If the push itself is
refused — a protection rule, a hook, a token without write — the run reports
exactly that, with the diff in the handoff comment, and never claims a push.

---

## Setup

**1. Install the caller into your repos.**

```bash
cp config.example.sh config.sh   # then fill in your accounts
./install.sh --dry-run           # see what would change
./install.sh                     # install
```

The installer reads each repo's workflows, takes their `name:` fields, and writes
a caller at `.github/workflows/ci-autofix.yml` that watches exactly those. Repos
requiring pull requests get one instead of a direct commit. Re-run it after adding
a workflow.

**2. Give it credentials.** Either a stored token, or none at all:

<table>
<tr><th>Workload identity federation <em>(recommended)</em></th><th>Stored secret</th></tr>
<tr valign="top"><td>

Nothing is stored. The run's GitHub OIDC token is exchanged for a short-lived
Anthropic token, scoped to one workflow.

Fill `ANTHROPIC_ORG_ID`, `ANTHROPIC_SERVICE_ACCOUNT_ID` and one
`FEDERATION_RULE_<owner>` in `config.sh`. Console setup is three steps and
[several traps](#federation-gotchas).

</td><td>

Set `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` as an org secret, or per
repo on a personal account.

Leave the federation values empty and this is what gets used.

</td></tr>
</table>

**3. Optionally set `CI_AUTOFIX_TOKEN`** — a token with `repo` + `workflow` scope.
Without it fixes still land and are still verified, but GitHub deliberately does not
start a new CI run for a push made with the built-in `GITHUB_TOKEN`, so the green
tick needs a manual re-run — and a pull request opened with the built-in token
needs the org or repo setting *Allow GitHub Actions to create and approve pull
requests* turned on. With the token, the pull request is opened as that user
and neither limit applies.

**4. After updating this repository, refresh the callers.** `./install.sh`
rewrites every repo's caller from `caller.template.yml`; a caller written before
`push_mode` existed keeps working with the defaults, but only a refresh gives it
the documented inputs.

---

## Keeping new repos covered

Three layers, because no single one catches everything:

| Layer | Covers | Misses |
|---|---|---|
| Your project template | New projects started from it | Anything not made from the template |
| [`sweep.yml`](.github/workflows/sweep.yml), daily | Every repo on every configured account, however it was created | Repos with no CI yet |
| `./install.sh` by hand | Whatever you point it at | Remembering to run it |

The sweep is the one that actually guarantees it. It enumerates the accounts and
installs the caller into any repo that has CI but no caller, and never touches a
repo that already has one.

---

## Switching it on

The reusable workflow ships **switched off**: its `enabled` input defaults to
`false` since 2026-09-17, when the fixer was turned off for cost. Every caller
runs `autofix.yml@main`, so that one default holds the whole fleet. Turn it
back on by flipping the default here, or by passing `enabled: true` from a
single caller to trial it on one repo first. The daily install sweep is gated
the same way, by the repository variable `CI_AUTOFIX_SWEEP_ENABLED`.

## What it costs, and what stops it

- **About $0.40** for a complete diagnose-fix-verify-push cycle on a small repo,
  plus a read-only second opinion on the cheaper model.
- **Nothing at all** when the diagnosis stops it: `env-data` and `unlinked`
  post a comment from the triage job and never start a model.
- **Three attempts per branch**, then it stops and asks for a person.
- **A human commit resets the counter**, so a branch you're actively working on is
  never starved.
- **Triage is a separate job** — a failure it declines to touch costs one runner
  second and no model tokens.
- **Dependabot branches are skipped** by default.
- The fix job times out at 90 minutes.

Only workflows that answer *"does this code work"* are watched. Policy guards,
deploys, security scanners and PR-metadata checks are excluded by name — they fail
for reasons a code change can't honestly fix. Any workflow can opt out with a
`# ci-autofix: ignore` comment.

---

## Federation gotchas

These cost hours to find. The Console's **Authentication events** tab names the
failing condition on every attempt, which is the only reason they were tractable —
check it first, always.

**The guided rule form seeds `event_name: push`.** Left alone it silently rejects
every run, because this is triggered by `workflow_run`.

**The subject is normalised to embed numeric IDs:**

```
repo:<org>@<org_id>/<repo>@<repo_id>:ref:<ref>
```

So `repo:my-org/*` never matches — there's no numeric ID in it.

**The subject field is an exact match unless it ends in a single trailing `*`.**
So `repo:my-org@123456/` fails too. The value you want is `repo:my-org@123456/*`.

**A rule enabled in all workspaces needs `anthropic_workspace_id` passed
explicitly**, or the exchange fails with `workspace_id_required`.

**One rule per GitHub account.** The subject belongs to the repo whose CI failed —
the caller — so a single rule cannot span two accounts.

**Pin the rule to this workflow.** Matching `job_workflow_ref` against
`<owner>/<repo>/.github/workflows/autofix.yml@refs/heads/main` means only this
reusable workflow can mint a token, not every workflow in every repo you own.

---

## Layout

```
.github/workflows/autofix.yml   the reusable workflow every repo calls
.github/workflows/sweep.yml     daily install sweep
.github/workflows/ci.yml        this repo's own checks
caller.template.yml             what gets written into each repo
install.sh                      rollout and refresh
config.example.sh               copy to config.sh — gitignored
PLAYBOOK.md                     the instructions the model follows
scripts/
  triage.sh                     should we try, and which attempt is this
  collect-evidence.sh           first error in context, plus the tail; run.json for the diagnosis
  diagnose.sh                   class, failing tests, the branch's files, allowed_paths
  scope-settings.sh             allowed_paths → the deny list the fixer runs under
  fingerprint.sh                counts tests and assertions
  prior-attempts.sh             what earlier attempts already tried
  honesty-guard.sh              blocks a bought green tick, a change outside scope, or one too big
  second-opinion.sh             parses the reviewer's VERDICT; anything but APPROVE stops the run
  verify.sh                     re-runs the repo's checks; the failing test must have run
  write-commit-message.sh       adds the trailers, the diagnosis and the verdict
  push-fix.sh                   pull request by default; direct only with both gates green
  watch-rerun.sh                reports how the re-run went
  handoff.sh                    explains a stop, with the diagnosis, verdict and diff
tests/guard_test.sh             tests for every script above that decides something
```

Built on [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).

## License

MIT — see [LICENSE](LICENSE).
