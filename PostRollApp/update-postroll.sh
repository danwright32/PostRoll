#!/usr/bin/env bash
set -euo pipefail

# Update PostRoll on Dan's behalf, from the button in the out of date sheet
# (#686).
#
# Usage:
#   update-postroll.sh --repo <checkout> --progress <file> --outcome <file> \
#                      --log <file> [--pull]
#
# Why this is a separate script rather than something PostRoll runs itself:
# build-install.sh QUITS the running PostRoll before it replaces
# /Applications/PostRoll.app, and then reopens it. Anything doing the update
# from inside the app would therefore be killed halfway through its own work.
# This runs as a child that outlives the quit, and reports through files rather
# than through a pipe, because the reader on the other end of a pipe goes away
# with the app.
#
# It writes three things:
#
#   --progress  the step file, in the same shape postroll/ai/progress.py writes
#               for a generation, so the app shows it through the one progress
#               indicator it already has rather than a second one grown here.
#               `updated_at` moves on every line of output, not only when a
#               phase changes: it is the heartbeat, and a phase label on its own
#               freezes exactly as silently as a spinner.
#   --outcome   how it ended, written once, at the end. This is the durable
#               half: when the update reaches the install step the app is gone,
#               so a failure after that point has no screen to appear on. The
#               next launch reads this file (L148, L164).
#   --log       everything the build said, appended, for when the outcome's last
#               few lines are not enough.
#
# The outcome file is REMOVED before the run starts. An earlier attempt's
# outcome left on disk is indistinguishable from this one's, and would have the
# next launch report a failure for an update that had just succeeded (L133).

REPO=""
PROGRESS=""
OUTCOME=""
LOG=""
PULL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="${2:-}"; shift 2 ;;
    --progress) PROGRESS="${2:-}"; shift 2 ;;
    --outcome)  OUTCOME="${2:-}"; shift 2 ;;
    --log)      LOG="${2:-}"; shift 2 ;;
    --pull)     PULL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Spelled out rather than lowercased from the variable name: `${name,,}` is a
# bash 4 expansion and the bash macOS ships is 3.2, so it would fail here while
# working perfectly under a Homebrew shell.
for required in "--repo:${REPO}" "--progress:${PROGRESS}" "--outcome:${OUTCOME}" "--log:${LOG}"; do
  if [[ -z "${required#*:}" ]]; then
    echo "Error: ${required%%:*} is required" >&2
    exit 2
  fi
done

mkdir -p "$(dirname "$PROGRESS")" "$(dirname "$OUTCOME")" "$(dirname "$LOG")"

# A GUI app hands its children a bare PATH, so xcodebuild, git and make are
# there but anything from Homebrew (xcbeautify) is not. Appended rather than
# prepended: what the caller set still wins, which keeps this from quietly
# overriding a deliberately chosen tool.
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"

STARTED_AT="$(date +%s)"
PHASE_FILE="$(dirname "$PROGRESS")/.update-phase"
BUILD_INSTALL="${REPO}/PostRollApp/build-install.sh"
ESC="$(printf '\033')"

rm -f "$OUTCOME"
printf '%s' "Starting" > "$PHASE_FILE"

# ── writing JSON from a shell, safely ────────────────────────────────────────

# A single line, for a label. Control characters are dropped rather than
# escaped: a label is text the app renders, and there is nothing a control
# character in one could mean.
json_string() {
  printf '%s' "$1" \
    | tr -d '\000-\037\177' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Many lines, for a failure message. Newlines survive as \n, colour codes are
# stripped (the build's output is coloured when xcbeautify is installed, and
# the residue of a half-removed escape sequence is worse than no colour), and
# tabs become spaces so indentation is kept without needing escaping.
json_lines() {
  sed -e "s/${ESC}\[[0-9;]*[a-zA-Z]//g" \
    | tr '\011' ' ' \
    | tr -d '\000-\011\013-\037\177' \
    | awk 'BEGIN { ORS = "" }
           { gsub(/\\/, "\\\\"); gsub(/"/, "\\\"");
             if (NR > 1) printf "\\n";
             printf "%s", $0 }'
}

LAST_BEAT=0

# Atomic, because the app reads this file on a timer and a half-written one
# decodes as nothing, which reads as a run that has not reported yet.
write_progress() {
  local label="$1" done_flag="${2:-false}" now
  now="$(date +%s)"
  printf '{"label":"%s","updated_at":%s,"started_at":%s,"done":%s}\n' \
    "$(json_string "$label")" "$now" "$STARTED_AT" "$done_flag" \
    > "${PROGRESS}.tmp"
  mv -f "${PROGRESS}.tmp" "$PROGRESS"
  LAST_BEAT="$now"
}

write_outcome() {
  local ok="$1" exit_code="$2" phase="$3" message="$4"
  printf '{"ok":%s,"exit_code":%s,"phase":"%s","message":"%s","finished_at":%s}\n' \
    "$ok" "$exit_code" "$(json_string "$phase")" "$message" "$(date +%s)" \
    > "${OUTCOME}.tmp"
  mv -f "${OUTCOME}.tmp" "$OUTCOME"
}

current_phase() {
  cat "$PHASE_FILE" 2>/dev/null || printf '%s' "Updating PostRoll"
}

# The last of what the build said, as one escaped JSON string.
tail_of_log() {
  tail -n 20 "$LOG" 2>/dev/null | json_lines
}

# `message` arrives ALREADY escaped, because both of its sources are escaped
# where they are produced: a tail of the log through `json_lines`, and the
# launcher's own refusal below. Escaping it again here would double every
# backslash in a compiler error.
fail() {
  local exit_code="$1" message="$2"
  write_outcome false "$exit_code" "$(current_phase)" "$message"
  # The step file is left holding the phase it died in. Clearing it would take
  # away the only thing on screen naming where it stopped.
  exit "$exit_code"
}

# Run one command, streaming its output into the log and turning its `==> `
# markers into the phase the app shows.
#
# The phase is persisted to a file rather than kept in a variable: the reading
# loop is the right hand side of a pipe, so it runs in a subshell and anything
# it assigns is gone by the time the caller looks.
run_step() {
  local label="$1"; shift
  printf '%s' "$label" > "$PHASE_FILE"
  write_progress "$label"

  set +e
  "$@" 2>&1 | while IFS= read -r line; do
      printf '%s\n' "$line" >> "$LOG"
      case "$line" in
        "==> "*)
          phase="${line#==> }"
          printf '%s' "$phase" > "$PHASE_FILE"
          write_progress "$phase"
          ;;
        *)
          # Throttled to once a second. The heartbeat only has to be finer
          # than the silence threshold it is measured against, and a build
          # prints thousands of lines.
          now="$(date +%s)"
          if [[ "$now" != "$LAST_BEAT" ]]; then
            write_progress "$(current_phase)"
          fi
          ;;
      esac
    done
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# ── the update itself ────────────────────────────────────────────────────────

if [[ ! -x "$BUILD_INSTALL" ]]; then
  # The launcher's own failure. Nothing inside build-install.sh can report that
  # build-install.sh is not there, and with no record at all this is
  # indistinguishable from the button never having been pressed (L164).
  fail 2 "$(printf '%s' "The build script is missing or not executable: ${BUILD_INSTALL}. This checkout is not one PostRoll can build from." | json_lines)"
fi

# `|| status=$?` rather than `if ! run_step`, because inside the branch of an
# inverted test `$?` is the inversion's own status, which is always zero: the
# exit code the build actually gave would be lost and every failure would be
# recorded as a success that somehow got here.
if [[ "$PULL" == "1" ]]; then
  # First, because a build on a checkout that is still behind produces another
  # copy missing the same work, which is the loop the sheet's two separate
  # remedies exist to break.
  status=0
  run_step "Getting the newest code" git -C "$REPO" pull || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$status" "$(tail_of_log)"
  fi
fi

status=0
run_step "Starting the build" "$BUILD_INSTALL" --launch || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "$status" "$(tail_of_log)"
fi

write_progress "Updated" true
write_outcome true 0 "$(current_phase)" ""
