#!/usr/bin/env bash
# Land the commit at HEAD on main through a pull request.
#
# Since 2 Nov 2026 main is under the org's "PR required" ruleset: one
# approval, the approver is not the last pusher, and nobody may bypass it.
# The release workflows can no longer push to main, so this pushes HEAD to
# a branch, opens a PR, waits for a maintainer to approve it and merges it
# (or notices that the maintainer merged it by hand).
#
# Like the direct push it replaces, it never lands a commit on a main that
# moved after the workflow checked it out: the PR is closed and the run
# fails, to be re-run against the new main.
#
# Usage: scripts/merge-via-pr.sh BRANCH_PREFIX TITLE [IF_LEFT_OPEN]
#   BRANCH_PREFIX  e.g. chore/kane-cli-0.10.11; the run id is appended, so a
#                  re-run never pushes over an earlier run's branch. Open
#                  PRs from an earlier run with the same prefix are closed.
#   TITLE          PR title and the squash commit's subject
#   IF_LEFT_OPEN   what a maintainer must do after merging a PR this run
#                  gave up waiting on
#
# Needs GH_TOKEN with contents and pull-requests write, and an `origin` the
# checkout can push to. WAIT_SECONDS (default 5h30m, inside a hosted job's
# 6-hour limit) and POLL_SECONDS (default 30) exist for the test harness.
set -euo pipefail

PREFIX="$1" TITLE="$2" IF_LEFT_OPEN="${3:-}"
WAIT_SECONDS="${WAIT_SECONDS:-19800}"
POLL_SECONDS="${POLL_SECONDS:-30}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
BRANCH="${PREFIX}-run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
HEAD_SHA="$(git rev-parse HEAD)"
BASE_SHA="$(git rev-parse HEAD^)"

# A run that timed out leaves its PR open. It is superseded, not merged:
# approving it later would land nothing, since its run is gone.
gh pr list --state open --base main --json url,headRefName \
  --template '{{range .}}{{.url}}{{"\t"}}{{.headRefName}}{{"\n"}}{{end}}' |
  while IFS=$'\t' read -r url head; do
    case "$head" in
      "$PREFIX"-run-*) gh pr close "$url" --comment "Superseded by ${RUN_URL}." ;;
    esac
  done

git push origin "HEAD:refs/heads/${BRANCH}"
URL="$(gh pr create --base main --head "$BRANCH" --title "$TITLE" \
  --body "Opened by ${RUN_URL}. Approve it and that run merges it; nothing else is needed.")"
echo "::notice::Approve ${URL}: this run merges it once approved (merging it yourself works too) and waits up to $((WAIT_SECONDS / 60)) minutes."
echo "Waiting for approval: ${URL}" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

close_branch() { git push -q origin --delete "$BRANCH" 2>/dev/null || true; }
pr_state() {
  gh pr view "$URL" --json state,reviewDecision --template '{{.state}} {{.reviewDecision}}{{"\n"}}' || true
}
deadline=$((SECONDS + WAIT_SECONDS))
wait_or_give_up() {
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::${URL} was not approved within $((WAIT_SECONDS / 60)) minutes. It is still open: approve and merge it${IF_LEFT_OPEN:+, $IF_LEFT_OPEN}."
    exit 1
  fi
  sleep "$POLL_SECONDS"
}
while :; do
  read -r state review <<< "$(pr_state)" || true
  case "$state" in
    MERGED) echo "${URL} is merged."; close_branch; exit 0 ;;
    CLOSED) echo "::error::${URL} was closed without merging, so main is unchanged."; exit 1 ;;
    OPEN) ;;
    *) echo "Could not read ${URL}; retrying in ${POLL_SECONDS}s." ;;
  esac

  if [ "$state" = OPEN ]; then
    if ! git fetch -q origin main; then
      echo "Could not fetch main; retrying in ${POLL_SECONDS}s."
      wait_or_give_up
      continue
    fi
    if [ "$(git rev-parse origin/main)" != "$BASE_SHA" ]; then
      gh pr close "$URL" --comment "main moved while this waited; re-run ${RUN_URL} against the new main."
      close_branch
      echo "::error::main moved after this run checked it out, so ${URL} was closed rather than landed over the newer main. Re-run the workflow."
      exit 1
    fi
    if [ "$review" = APPROVED ]; then
      if gh pr merge "$URL" --squash --subject "$TITLE" --body "" --match-head-commit "$HEAD_SHA"; then
        # main now holds the squash commit, so the moved-main check above no
        # longer applies; only confirm GitHub reports the PR merged.
        for _ in 1 2 3 4 5 6; do
          read -r state review <<< "$(pr_state)" || true
          [ "$state" = MERGED ] && { echo "${URL} is merged."; close_branch; exit 0; }
          sleep 5
        done
        echo "::error::GitHub accepted the merge of ${URL} but does not report it merged; check it before re-running."
        exit 1
      fi
      echo "Merging ${URL} was refused; retrying in ${POLL_SECONDS}s."
    fi
  fi

  wait_or_give_up
done
