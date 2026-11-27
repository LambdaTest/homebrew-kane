#!/usr/bin/env bash
# Harness for scripts/merge-via-pr.sh, the step both release workflows use
# to land a commit on main now that main takes changes only through an
# approved PR.
#
# A local bare repository plays GitHub and scripts/fixtures/fake-gh plays
# `gh pr`, so each case runs the real script end to end: push the branch,
# open the PR, wait, merge or give up, and leave main as it should be.
#
# Usage: scripts/test-merge-via-pr.sh
set -uo pipefail
# (No -e: several cases run the script expecting it to FAIL.)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/merge-via-pr.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir "$WORKDIR/bin"
ln -s "$REPO_ROOT/scripts/fixtures/fake-gh" "$WORKDIR/bin/gh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { local msg="$1"; shift; if "$@"; then pass "$msg"; else fail "$msg"; fi; }

g() { git -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }

# new_case NAME: a bare remote with one commit on main, and a clone with
# the formula change committed on top, as the workflow leaves it.
new_case() {
  C="$WORKDIR/$1"
  mkdir -p "$C/state"
  g init -q --bare --initial-branch=main "$C/remote.git"
  echo "$C/remote.git" > "$C/state/remote"
  g clone -q "$C/remote.git" "$C/seed" 2>/dev/null
  echo 'version "0.1.17"' > "$C/seed/kane-cli.rb"
  g -C "$C/seed" add kane-cli.rb && g -C "$C/seed" commit -q -m initial && g -C "$C/seed" push -q origin main
  g clone -q "$C/remote.git" "$C/work"
  echo 'version "0.1.18"' > "$C/work/kane-cli.rb"
  g -C "$C/work" commit -q -am "Update kane-cli to 0.1.18"
  BASE="$(g -C "$C/work" rev-parse HEAD^)"
  HEAD_SHA="$(g -C "$C/work" rev-parse HEAD)"
}

# run_script: run the real script in the clone; output in $OUT, status in $RC.
run_script() {
  OUT="$(cd "$C/work" && PATH="$WORKDIR/bin:$PATH" FAKE_GH_STATE="$C/state" \
    GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=LambdaTest/homebrew-kane \
    WAIT_SECONDS="${WAIT:-3}" POLL_SECONDS=1 \
    bash "$SCRIPT" chore/kane-cli-0.1.18 "Update kane-cli to 0.1.18" "then run Build bottles" 2>&1)"
  RC=$?
}

main_is() { [ "$(git --git-dir "$C/remote.git" rev-parse refs/heads/main)" = "$1" ]; }
branch_gone() { ! git --git-dir "$C/remote.git" rev-parse -q --verify refs/heads/chore/kane-cli-0.1.18-run-7-1 >/dev/null; }
called() { grep -q -- "$1" "$C/state/calls"; }
said() { grep -q -- "$1" <<< "$OUT"; }

# 1. Approved: the script merges it and main gets exactly this commit.
new_case approved
run_script
check "approved: exits 0" [ "$RC" = 0 ]
check "approved: main is the formula commit" main_is "$HEAD_SHA"
check "approved: merged by squash, pinned to the pushed head" called "pr merge https://github.com/LambdaTest/homebrew-kane/pull/101 --squash --subject Update kane-cli to 0.1.18 --body  --match-head-commit $HEAD_SHA"
check "approved: the run's branch is deleted" branch_gone
check "approved: the PR link is printed for the approver" said "::notice::Approve https://github.com/LambdaTest/homebrew-kane/pull/101"

# 2. A maintainer approves and merges it by hand: the script just notices.
new_case human-merge
printf 'OPEN REVIEW_REQUIRED\nMERGED APPROVED\n' > "$C/state/views"
run_script
check "hand-merged: exits 0" [ "$RC" = 0 ]
check "hand-merged: the script never merges" bash -c "! grep -q 'pr merge' '$C/state/calls'"
check "hand-merged: the run's branch is deleted" branch_gone

# 3. Closed without merging: fails, main untouched.
new_case closed
printf 'OPEN REVIEW_REQUIRED\nCLOSED REVIEW_REQUIRED\n' > "$C/state/views"
run_script
check "closed: exits non-zero" [ "$RC" != 0 ]
check "closed: says so" said "closed without merging"
check "closed: main untouched" main_is "$BASE"

# 4. Never approved: gives up at the deadline, leaves the PR open, says what to do.
new_case timeout
echo 'OPEN REVIEW_REQUIRED' > "$C/state/views"
WAIT=2 run_script
check "timeout: exits non-zero" [ "$RC" != 0 ]
check "timeout: names the open PR and the follow-up" said "pull/101 was not approved within 0 minutes. It is still open: approve and merge it, then run Build bottles."
check "timeout: the PR is left open" bash -c "! grep -q 'pr close' '$C/state/calls'"
check "timeout: main untouched" main_is "$BASE"

# 5. Merge refused (e.g. a rule the approval did not satisfy): keeps waiting, then gives up.
new_case refused
FAKE_GH_REFUSE_MERGE=1 WAIT=2 run_script
check "refused: exits non-zero" [ "$RC" != 0 ]
check "refused: retried rather than failing on the first refusal" [ "$(grep -c 'pr merge' "$C/state/calls")" -ge 2 ]
check "refused: main untouched" main_is "$BASE"

# 6. main moved after checkout: the PR is closed, never merged over the newer main.
new_case moved
echo 'version "0.1.19"' > "$C/seed/kane-cli.rb"
g -C "$C/seed" commit -q -am "Update kane-cli to 0.1.19" && g -C "$C/seed" push -q origin main
NEWER="$(git --git-dir "$C/remote.git" rev-parse refs/heads/main)"
run_script
check "moved: exits non-zero" [ "$RC" != 0 ]
check "moved: says main moved" said "main moved after this run checked it out"
check "moved: the newer main stays" main_is "$NEWER"
check "moved: never merged" bash -c "! grep -q 'pr merge' '$C/state/calls'"
check "moved: its own PR is closed" grep -qx "https://github.com/LambdaTest/homebrew-kane/pull/101" "$C/state/closed"

# 7. An earlier run's open PR for the same prefix is closed; others are left alone.
new_case superseded
printf '%s\t%s\n' \
  https://github.com/LambdaTest/homebrew-kane/pull/90 chore/kane-cli-0.1.18-run-5-1 \
  https://github.com/LambdaTest/homebrew-kane/pull/91 chore/kane-cli-0.1.18-bottles-run-5-1 \
  https://github.com/LambdaTest/homebrew-kane/pull/92 chore/kane-cli-0.1.19-run-6-1 \
  https://github.com/LambdaTest/homebrew-kane/pull/93 feat/AA-1 > "$C/state/open"
run_script
check "superseded: exits 0" [ "$RC" = 0 ]
check "superseded: the earlier same-prefix PR is closed" grep -qx "https://github.com/LambdaTest/homebrew-kane/pull/90" "$C/state/closed"
check "superseded: only that one" [ "$(wc -l < "$C/state/closed" | tr -d ' ')" = 1 ]

exit "$FAIL"
