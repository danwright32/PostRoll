#!/bin/bash
# The states the hand check needs, built without going near real data (#866).
#
# Three questions about this app can only be answered by driving it: whether
# closing the window leaves it running and reachable (#847), whether Return
# commits a hand opened form but not a link raised one (#848), and what the
# alerts actually put on screen (#855). XCUITest cannot read into a PostRoll
# window, which #860 records in full, so each was answered by hand and each
# answer lived only in an issue comment. docs/HAND-CHECK.md is the routine that
# replaces those comments; this is what puts the app into each state it asks
# about.
#
# ## Why a script rather than a paragraph of instructions
#
# Several steps need a deliberately broken store, and doing that to the real
# events.json would be a bad afternoon. `AppPaths` honours POSTROLL_DATA_DIR and
# POSTROLL_PROJECT_DIR before anything else and unconditionally, so a launch
# through here is structurally unable to reach live data (L2). That is a
# property of this file, not a rule for whoever is running the check to
# remember: a rule that has to be retyped per step is one that will be missed on
# the step that matters.
#
# ## Why the binary rather than `open`
#
# `open -a` gives no way to set the environment, so it would launch a copy
# pointed at the real library. The executable inside the installed bundle is run
# directly instead. That has one consequence worth knowing: the link step below
# goes through LaunchServices, which picks a handler for `postroll://` on its
# own, and fourteen PostRoll bundles have been registered on the development
# machine over time. So the link step proves which process actually answered
# rather than assuming it was this one (L70).

set -euo pipefail

APP="/Applications/PostRoll.app"
BINARY="${APP}/Contents/MacOS/PostRoll"
WORLD="${POSTROLL_HAND_CHECK_WORLD:-${HOME}/Library/Caches/PostRollHandCheck}"
DATA="${WORLD}/data"
NOT_A_CHECKOUT="${WORLD}/not-a-checkout"
STORE="${DATA}/events.json"
# Written into every world this script builds, and required before it deletes
# one. See remove_world.
MARKER="${WORLD}/.postroll-hand-check"

usage() {
  cat >&2 <<'USAGE'
usage: hand-check.sh <command> [--no-launch]

States, each of which rebuilds the scratch world and launches the app in it:
  healthy             a readable, empty store and a real code folder
  no-code-folder      a good store, with the code folder pointed somewhere
                      that is not a checkout
  corrupt-store       events.json present and not valid JSON
  unreadable-store    events.json present and unreadable (chmod 000)
  both-broken         unreadable store AND a broken code folder, which is the
                      state #855 was found in

Actions on the world a state left behind:
  repair-store        make the unreadable store readable again, so Try Again
                      has something to succeed at
  link                fire a well formed postroll:// link and say which
                      process answered it
  status              say what is running and which world it is pointed at
  end                 quit every copy and delete the scratch world

--no-launch builds the state and stops, without starting the app.

POSTROLL_HAND_CHECK_WORLD moves the scratch world somewhere other than
~/Library/Caches/PostRollHandCheck. Nothing is deleted from a folder this
script did not make, whichever location it is pointed at.
USAGE
  exit 64
}

# Every copy of PostRoll running from the INSTALLED bundle, by executable path
# rather than by name: a Debug build and a Release build are both called
# PostRoll, and asking by name cannot tell them apart.
running_pids() {
  pgrep -f "^${BINARY}$" || true
}

# Any PostRoll at all, however it was launched. Used to say when the answer to
# "which copy is this about" is undecided.
every_postroll_pid() {
  pgrep -f "PostRoll.app/Contents/MacOS/PostRoll" || true
}

require_installed() {
  if [[ ! -x "${BINARY}" ]]; then
    echo "no installed PostRoll at ${BINARY}. Run 'make install' first." >&2
    exit 1
  fi
}

require_world() {
  if [[ ! -d "${DATA}" ]]; then
    echo "there is no scratch world at ${WORLD}, so there is nothing to act on." >&2
    echo "Start a state first, for example: ./PostRollApp/hand-check.sh both-broken" >&2
    exit 1
  fi
}

quit_every_copy() {
  local pids
  pids="$(every_postroll_pid)"
  [[ -z "${pids}" ]] && return 0
  # shellcheck disable=SC2086
  kill ${pids} 2>/dev/null || true
  for _ in $(seq 1 25); do
    [[ -z "$(every_postroll_pid)" ]] && return 0
    sleep 0.2
  done
  # shellcheck disable=SC2086
  kill -9 $(every_postroll_pid) 2>/dev/null || true
  sleep 0.5
}

# Delete the scratch world, and ONLY if this script is the thing that made it.
#
# Every state starts by clearing the world, and the location is overridable, so
# this is a recursive delete of a path that came from outside. The check on that
# path used to live in `launch_in`, which runs after the delete: a check that
# happens after the destruction can only ever confirm what has already been done
# (L5).
#
# A marker file rather than a rule about what the path looks like. Any path rule
# has to be loose enough to allow an override and strict enough to refuse a home
# directory, and there is no such rule. The marker answers the question actually
# being asked: did this script make this folder.
remove_world() {
  [[ -e "${WORLD}" ]] || return 0
  if [[ ! -f "${MARKER}" ]]; then
    echo "refusing to delete ${WORLD}: it exists and this script did not make" >&2
    echo "it (no ${MARKER}). Point POSTROLL_HAND_CHECK_WORLD somewhere else, or" >&2
    echo "remove that folder yourself if it really is scratch." >&2
    exit 1
  fi
  # Readable first. A store left at mode 000 cannot be removed from a folder
  # that can otherwise be read, and a cleanup that half worked leaves the next
  # run starting from a state nobody chose.
  [[ -e "${STORE}" ]] && chmod 644 "${STORE}"
  rm -rf "${WORLD}"
}

build_world() {
  local state="$1"
  remove_world
  mkdir -p "${DATA}" "${NOT_A_CHECKOUT}"
  date > "${MARKER}"
  # Something in it, so the folder is not merely empty: the app treats a missing
  # code folder and one that is not a checkout as different problems, and only
  # the second is what this state means.
  echo "not a checkout" > "${NOT_A_CHECKOUT}/README.txt"

  case "${state}" in
    healthy|no-code-folder)
      echo '[]' > "${STORE}"
      ;;
    corrupt-store)
      echo 'this is not json' > "${STORE}"
      ;;
    unreadable-store|both-broken)
      echo '[]' > "${STORE}"
      chmod 000 "${STORE}"
      ;;
  esac
}

launch_in() {
  local state="$1"
  # The one place the data location is decided. Asserted rather than trusted,
  # because every destructive step in the checklist rests on it and a typo here
  # would point a deliberately broken store at the real library.
  case "${DATA}" in
    *"/PostRollHandCheck/data") ;;
    *) echo "refusing to launch: ${DATA} is not a scratch world" >&2; exit 1 ;;
  esac

  quit_every_copy

  local project="${PWD}"
  case "${state}" in
    no-code-folder|both-broken) project="${NOT_A_CHECKOUT}" ;;
  esac

  POSTROLL_DATA_DIR="${DATA}" POSTROLL_PROJECT_DIR="${project}" "${BINARY}" &
  disown || true

  for _ in $(seq 1 60); do
    [[ -n "$(running_pids)" ]] && break
    sleep 0.5
  done
  local pids
  pids="$(running_pids)"
  if [[ -z "${pids}" ]]; then
    echo "PostRoll did not start, so nothing after this is about a running app." >&2
    exit 1
  fi
  echo "PostRoll is running as pid ${pids}"
  echo "  data:        ${DATA}"
  echo "  code folder: ${project}"
}

command="${1:-}"
[[ -z "${command}" ]] && usage
no_launch=0
[[ "${2:-}" == "--no-launch" ]] && no_launch=1

case "${command}" in
  healthy|no-code-folder|corrupt-store|unreadable-store|both-broken)
    build_world "${command}"
    echo "built the ${command} world at ${WORLD}"
    if [[ "${no_launch}" == "0" ]]; then
      require_installed
      launch_in "${command}"
    fi
    ;;

  repair-store)
    require_world
    if [[ ! -e "${STORE}" ]]; then
      echo "there is no store at ${STORE} to repair." >&2
      exit 1
    fi
    chmod 644 "${STORE}"
    echo "${STORE} is readable again. Press Try Again in PostRoll."
    ;;

  link)
    require_world
    # A well formed link, so the only thing under test is what the window does
    # with it. The booking id is fixed rather than generated: firing the same
    # link twice must be seen to say the event already exists, and a fresh id
    # each time would quietly make a second event instead.
    url="postroll://new?name=Hand%20check&org=Test%20Company&venue=Test%20Hall&room=Main%20Stage&date=20260901&booking=6C2F1A44-0000-4000-8000-000000000001"
    before="$(every_postroll_pid | tr '\n' ' ')"
    open "${url}"
    sleep 2
    after="$(every_postroll_pid | tr '\n' ' ')"
    echo "link fired: ${url}"
    echo "  PostRoll pids before: ${before:-none}"
    echo "  PostRoll pids after:  ${after:-none}"
    if [[ "${before}" != "${after}" ]]; then
      echo "  WARNING: the set of running copies CHANGED, so LaunchServices" >&2
      echo "  started a copy rather than handing the link to the one under" >&2
      echo "  test. That copy is pointed at the REAL library. Quit it before" >&2
      echo "  going on, and treat this step's result as meaning nothing." >&2
      exit 1
    fi
    ;;

  status)
    installed="$(running_pids | tr '\n' ' ')"
    everything="$(every_postroll_pid | tr '\n' ' ')"
    echo "installed copy running as: ${installed:-none}"
    echo "every PostRoll running:    ${everything:-none}"
    if [[ -d "${WORLD}" ]]; then
      echo "scratch world:             ${WORLD}"
      if [[ -e "${STORE}" ]]; then
        echo "store:                     $(stat -f '%Sp %z bytes' "${STORE}")"
      else
        echo "store:                     absent"
      fi
    else
      echo "scratch world:             none"
    fi
    ;;

  end)
    quit_every_copy
    remove_world
    echo "every copy quit and ${WORLD} is gone"
    ;;

  *)
    echo "unknown command: ${command}" >&2
    usage
    ;;
esac
