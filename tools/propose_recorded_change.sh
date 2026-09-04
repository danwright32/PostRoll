#!/usr/bin/env bash
#
# Open (or update) the pull request that proposes a re-recorded fixture.
#
# Shared by record-suite-count.yml and record-guard-costs.yml, which had this
# block copied into each of them character for character. Two copies of one
# rule is two places for it to be wrong, and it was wrong in both (#1311).
#
# The branch is named for the DAY, so the second run of any day meets the first
# run's own output (#1321, L393). That is handled by building ON today's
# proposal rather than over it:
#
#   * the branch is fetched, and when it is there this run's reading is
#     committed on top of it, so the push is an ordinary fast forward. Nothing
#     an earlier run wrote is discarded, which is what a lease was there to
#     protect (L5);
#   * `--force-with-lease` is deliberately NOT used. It takes its lease from
#     the remote tracking ref and finds that ref through the configured fetch
#     refspec, which on a runner names only the branch actions/checkout
#     checked out. The day branch is untracked however many times it is
#     fetched, so the lease has no value and git refuses with `stale info`.
#     Fetching the branch first (#1326) does not change that, and the test
#     beside this measures the refusal rather than trusting this paragraph
#     (tests/test_recorded_change_is_proposed.py);
#   * whether a proposal is already open is asked with `gh pr list --state
#     open`, never `gh pr view <branch>`, which answers about the newest pull
#     request on that head whatever its state. Once today's proposal is merged
#     and its branch deleted, `pr view` still reports it, and the run would
#     push a branch and open nothing for it (L98). #1322 merged at 13:51 on
#     the day its own branch would be reused.
#
# Two seams, both real unless a test sets them:
#   GH             the gh executable            (default: gh)
#   PROPOSAL_DATE  the day the branch is named for (default: today, UTC)

set -euo pipefail

record=""
prefix=""
title=""
body=""

while [ $# -gt 0 ]; do
  case "$1" in
    --record)        record="${2-}"; shift 2 ;;
    --branch-prefix) prefix="${2-}"; shift 2 ;;
    --title)         title="${2-}"; shift 2 ;;
    --body)          body="${2-}"; shift 2 ;;
    *) echo "propose_recorded_change: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Each of the four names what is proposed or what the proposal says. A default
# for any of them would let a caller that forgot it propose one record under
# another's title, which surfaces as a wrong pull request rather than as a
# refusal (L168).
[ -n "${record}" ] || { echo "propose_recorded_change: --record is required" >&2; exit 2; }
[ -n "${prefix}" ] || { echo "propose_recorded_change: --branch-prefix is required" >&2; exit 2; }
[ -n "${title}" ]  || { echo "propose_recorded_change: --title is required" >&2; exit 2; }
[ -n "${body}" ]   || { echo "propose_recorded_change: --body is required" >&2; exit 2; }

: "${GH:=gh}"
: "${PROPOSAL_DATE:=$(date -u +%Y-%m-%d)}"

branch="${prefix}/${PROPOSAL_DATE}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Kept aside because checking today's proposal out replaces the working tree
# copy, and the working tree copy is this run's whole measurement (L277).
kept="$(mktemp)"
cp "${record}" "${kept}"

# Put the working tree copy back the way the base has it before switching. The
# reading is already held aside, and restoring just this path rather than
# checking out with --force means any OTHER local change still stops the
# checkout rather than being thrown away by a step that is not about it (L5).
git checkout -q -- "${record}"

# `|| true` is not used here: the two outcomes are told apart, because they
# lead to different pushes and one of them is the state #1311 was about.
if git fetch origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null; then
  git checkout -q -B "${branch}" "refs/remotes/origin/${branch}"
  on_remote=true
else
  git checkout -q -B "${branch}"
  on_remote=false
fi

cp "${kept}" "${record}"
git add -- "${record}"

if git diff --cached --quiet; then
  if [ "${on_remote}" != "true" ]; then
    # The caller runs this only when the record MOVED, so a record equal to
    # what the base already holds, with no branch to explain it, means the
    # caller and this script disagree about what happened. Exiting 0 here
    # would be a run that proposed nothing and reported success (L98).
    echo "propose_recorded_change: ${record} matches the base and no ${branch}" \
         "exists, so there is nothing to propose" >&2
    exit 1
  fi
  echo "today's proposal on ${branch} already carries this record; nothing pushed"
else
  git commit -q -m "${title}"
  git push -q origin "${branch}"
fi

if [ "$("${GH}" pr list --head "${branch}" --state open --json number --jq 'length')" != "0" ]; then
  echo "today's proposal on ${branch} is already open; it has been updated in place"
  exit 0
fi

"${GH}" pr create \
  --base main \
  --head "${branch}" \
  --title "${title}" \
  --body "${body}"
echo "opened today's proposal on ${branch}"
