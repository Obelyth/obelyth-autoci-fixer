#!/usr/bin/env bash
# Turns the diagnosis into a Claude Code settings file whose deny rules stop
# the fixer editing anything the diagnosis did not implicate: tests, workflows,
# package manifests and lockfiles are off limits unless they are in
# allowed_paths. The honesty guard checks the same list after the fact; this
# just stops the model spending turns on edits that would be thrown away.
#
# Two facts about Claude Code's rules shape what is written here:
#
#   - Only `Edit(path)` rules are consulted for file permissions. They cover
#     Edit, Write, MultiEdit, NotebookEdit, and the file commands Claude Code
#     recognises in Bash (sed -i, tee, redirects). A `Write(path)` rule is
#     accepted but never consulted, so none are written.
#   - A `!pattern` deny entry carves its paths out of the entries before it,
#     but cannot reopen a file inside a directory that an earlier entry blocks
#     as a whole. So a directory rule (`tests/**`) that would swallow an
#     allowed path is replaced by one rule per sibling file instead, and only
#     the file-shaped rules (`**/*.test.*`, lockfiles) rely on negation.
#
# Inputs: DIAGNOSIS (path to diagnosis.json), SETTINGS_OUT (where to write).
set -uo pipefail

DIAGNOSIS="${DIAGNOSIS:-.ci-autofix/diagnosis.json}"
OUT="${SETTINGS_OUT:-${RUNNER_TEMP}/claude-settings.json}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
ENUMERATION_CAP=5000

mapfile -t ALLOWED < <(jq -r '.allowed_paths[]?' "$DIAGNOSIS" 2>/dev/null)
allowed_has() { local want="$1" a; for a in "${ALLOWED[@]}"; do [[ "$a" == "$want" ]] && return 0; done; return 1; }
any_allowed_matches() { local re="$1" a; for a in "${ALLOWED[@]}"; do [[ "$a" =~ $re ]] && return 0; done; return 1; }

git ls-files > "${RUNNER_TEMP}/scope-tracked.txt" 2>/dev/null || : > "${RUNNER_TEMP}/scope-tracked.txt"

RULES=()
NEGATIONS=()
DROPPED=()

# Directory-shaped: a deny rule with one directory segment matches that
# directory at any depth, which is what we want for monorepos.
for dir in tests test __tests__ spec specs .github .ci-autofix; do
  re="(^|/)${dir//./\\.}/"
  if any_allowed_matches "$re"; then
    mapfile -t siblings < <(grep -E "$re" "${RUNNER_TEMP}/scope-tracked.txt")
    if (( ${#siblings[@]} > ENUMERATION_CAP )); then
      DROPPED+=("$dir/**")
      continue
    fi
    for f in "${siblings[@]}"; do
      allowed_has "$f" || RULES+=("Edit($f)")
    done
  else
    RULES+=("Edit($dir/**)")
  fi
done

# File-shaped: the pattern goes in, and every allowed path it would catch is
# carved back out with a negation listed after it.
FILE_PATTERNS=(
  '**/*.test.*|\.test\.[^/]+$'
  '**/*.spec.*|\.spec\.[^/]+$'
  '**/*_test.*|_test\.[^/]+$'
  '**/*_spec.*|_spec\.[^/]+$'
  '**/test_*.py|(^|/)test_[^/]+\.py$'
  '**/*Tests.swift|Tests\.swift$'
  'package.json|(^|/)package\.json$'
  'package-lock.json|(^|/)package-lock\.json$'
  'pnpm-lock.yaml|(^|/)pnpm-lock\.yaml$'
  'yarn.lock|(^|/)yarn\.lock$'
  'bun.lock|(^|/)bun\.lock$'
  'bun.lockb|(^|/)bun\.lockb$'
  'uv.lock|(^|/)uv\.lock$'
  'poetry.lock|(^|/)poetry\.lock$'
  'Pipfile.lock|(^|/)Pipfile\.lock$'
  'Cargo.lock|(^|/)Cargo\.lock$'
  'go.sum|(^|/)go\.sum$'
  'go.mod|(^|/)go\.mod$'
  'Gemfile.lock|(^|/)Gemfile\.lock$'
  'composer.lock|(^|/)composer\.lock$'
  'Package.resolved|(^|/)Package\.resolved$'
  '*.toml|\.toml$'
  '*.cfg|\.cfg$'
)
for entry in "${FILE_PATTERNS[@]}"; do
  glob="${entry%%|*}"; re="${entry#*|}"
  RULES+=("Edit($glob)")
  for a in "${ALLOWED[@]}"; do
    [[ "$a" =~ $re ]] && NEGATIONS+=("Edit(!$a)")
  done
done

# Bash routes that write files without naming them to a file tool. The Edit
# rules already cover sed -i and tee; these are belt and braces for the rest.
RULES+=("Bash(git push:*)" "Bash(git reset:*)" "Bash(git rebase:*)" "Bash(git filter-branch:*)")

printf '%s\n' "${RULES[@]}" "${NEGATIONS[@]}" | sort -u -s | awk '!seen[$0]++' > "${RUNNER_TEMP}/scope-rules.txt"
# sort -u would move the negations before the rules they carve out; put them
# back at the end, where a negation has to sit to take effect.
{
  grep -v '^Edit(!' "${RUNNER_TEMP}/scope-rules.txt"
  grep '^Edit(!' "${RUNNER_TEMP}/scope-rules.txt" || true
} | jq -R . | jq -s '{permissions: {deny: .}}' > "$OUT"

if (( ${#DROPPED[@]} )); then
  echo "::warning::More than $ENUMERATION_CAP files under ${DROPPED[*]}; that directory rule was dropped and the honesty guard alone holds the line there."
fi

echo "path=$OUT" >> "$GITHUB_OUTPUT"
echo "deny_count=$(jq '.permissions.deny | length' "$OUT")" >> "$GITHUB_OUTPUT"
echo "Scope: $(jq '.permissions.deny | length' "$OUT") deny rules; allowed: ${ALLOWED[*]:-<nothing>}"
