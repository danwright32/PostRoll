#!/usr/bin/env bash
# Quit the PostRoll that is about to be replaced, and wait until it has (#1434).
#
# Sourced by build-install.sh. Its own file so the tests can drive it against a
# stand-in process without building or installing anything.
#
# The installer used to ask "PostRoll" to quit by NAME, sleep one second and
# delete the bundle whatever had happened. Two ways that went wrong:
#
# - PostRoll's quit guard answers a quit with its "still working" sheet while
#   background work is running (#862), so the app stayed open and its bundle
#   was replaced underneath it, and `open` then brought the OLD process forward.
# - A name reaches whichever copy macOS resolves, and this Mac has had fourteen
#   PostRoll bundles registered (#840).
#
# So the process is found by its EXECUTABLE PATH, asked to quit through the
# bundle at that path, and waited on by PID. If it is still there at the
# deadline the install stops before touching anything.

# Ask the app at a bundle path to quit. Replaced by POSTROLL_QUIT_APP in the
# tests, which say what their stand-in does when asked.
quit_bundle() {
  osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1
}

# quit_running_app <executable path> <bundle path> <deadline in seconds>
#
# Returns 0 when nothing is running at that path or it has exited, 1 when it
# is still running at the deadline.
quit_running_app() {
  local exe="$1" bundle="$2" deadline="$3"
  local poll="${POSTROLL_QUIT_POLL:-0.2}"
  local quit="${POSTROLL_QUIT_APP:-quit_bundle}"
  local pids
  # Anchored on the whole executable path, so another copy with the same
  # process name elsewhere is not this one.
  pids="$(pgrep -f "^${exe}( |$)" || true)"
  [[ -z "${pids}" ]] && return 0

  echo "    Quitting the running PostRoll (pid ${pids//$'\n'/, })..."
  "${quit}" "${bundle}" || true

  # Attempts rather than a clock: the budget is an upper bound, since each
  # attempt sleeps at least `poll`, and the only cost of overshooting is a
  # later refusal.
  local tries
  tries="$(awk -v d="${deadline}" -v p="${poll}" 'BEGIN { printf "%d", d / p + 1 }')"
  local pid alive
  while (( tries > 0 )); do
    alive=0
    for pid in ${pids}; do
      kill -0 "${pid}" 2>/dev/null && alive=1
    done
    (( alive == 0 )) && return 0
    sleep "${poll}"
    tries=$(( tries - 1 ))
  done

  {
    echo "Error: PostRoll is still open (pid ${pids//$'\n'/, }), so it was not"
    echo "       replaced. It is probably asking whether to quit while it"
    echo "       finishes something: press Quit Anyway there, or let it finish"
    echo "       and quit it yourself, then run the install again."
    echo "       Nothing was installed."
  } >&2
  return 1
}
