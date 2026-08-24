#!/bin/bash
# The states the hand check needs, built without going near real data (#866).
#
# Questions about this app that can only be answered by driving it: whether
# closing the window leaves it running and reachable (#847), whether Return
# commits a hand opened form but not a link raised one (#848), what happens when
# it is asked to quit with work in flight (#862), and what the Dock and
# Notification Center say (#863). Each was answered by hand and each answer
# lived only in an issue comment. docs/HAND-CHECK.md is the routine that
# replaces those comments; this is what puts the app into each state it asks
# about.
#
# The alerts used to be here too, on the recorded grounds that XCUITest cannot
# read into a PostRoll window. That was measured again on 2026-08-23 and is
# false, so they are asserted now rather than looked at
# (PostRollApp/UITests/LaunchAlertUITests.swift, #877). The broken store states
# below are kept: they are what the alert tests set up too, and the corrupt and
# unreadable worlds are still the quickest way to put a running app in front of
# somebody who needs to see one.
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
# Where the seeded state copies photographs to, and how many it takes.
PHOTOS="${WORLD}/photos"
SEED_PHOTO_CAP=8
# The seeded event's date, as seconds since Apple's 2001 reference date, which
# is what a plain JSONDecoder reads a Date as and therefore what EventStore
# reads. 2026-09-01 00:00:00 UTC, the same date the link step uses.
#
# A literal rather than computed from a date string, because this script has to
# run on the Linux runner its tests run on and `date -j -f` is BSD only. The
# test derives the number from the date itself, so the two are not one lookup.
SEED_DATE_SECONDS=809913600

usage() {
  cat >&2 <<'USAGE'
usage: hand-check.sh <command> [photo folder] [--no-launch]

States, each of which rebuilds the scratch world and launches the app in it:
  healthy             a readable, empty store and a real code folder
  no-code-folder      a good store, with the code folder pointed somewhere
                      that is not a checkout
  corrupt-store       events.json present and not valid JSON
  unreadable-store    events.json present and unreadable (chmod 000)
  both-broken         unreadable store AND a broken code folder, which is the
                      state #855 was found in
  seeded <folder>     a store holding ONE event, with up to 8 photographs
                      copied out of <folder>, so a generation can actually be
                      started. Every other state builds an empty store, and
                      Generate All is disabled until a day has a photo on it.
                      Add --no-code-folder to seed the same event and point the
                      app somewhere that is not a checkout, so a run started
                      from it fails.

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
    healthy|no-code-folder|seeded)
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

# MARK: - The state a generation can be started from (#879)

# Every photograph in a folder, one per line, top level only.
#
# Top level rather than recursive on purpose: a shoot folder usually holds
# exports, selects and raw files in folders beside each other, and a hand check
# that quietly reaches into all of them is one whose input nobody can predict.
images_in() {
  find "$1" -maxdepth 1 -type f \( \
    -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \
  \) | LC_ALL=C sort
}

# The photo folder is checked BEFORE anything is deleted.
#
# Every state begins by tearing the world down, so an argument checked after
# that can only confirm a deletion that has already happened (L5). Here that
# would take away the state whoever is mid checklist is standing in, in order
# to tell them they mistyped a path.
#
# An empty folder is refused rather than seeded from, because an event with no
# photographs leaves Generate All disabled: the checklist step then reads as
# the app being broken, and a setup that silently did nothing is the one thing
# a check must never be able to report as a pass (L98).
require_photo_folder() {
  local source="${1:-}"
  if [[ -z "${source}" ]]; then
    echo "seeded needs a photo folder to copy from, for example:" >&2
    echo "  ./PostRollApp/hand-check.sh seeded ~/Pictures/some-shoot" >&2
    exit 64
  fi
  if [[ ! -d "${source}" ]]; then
    echo "no photo folder at ${source}, so there is nothing to seed an event with." >&2
    exit 1
  fi
  if [[ -z "$(images_in "${source}")" ]]; then
    echo "no photographs in ${source} (looked for jpg, jpeg, png and heic at the" >&2
    echo "top level). An event with no photos leaves Generate All disabled, so" >&2
    echo "there would be nothing to press in step 6." >&2
    exit 1
  fi
}

# Percent encode a path for a file URL.
#
# The world can be pointed anywhere, so its path is not ours to assume: a space
# in it produces a URL the app resolves to a different file, and a day whose
# photos cannot be opened is the same dead end as a day with no photos. The
# loop runs in the C locale so a multibyte character is encoded as its bytes,
# which is what a URL wants.
url_encode_path() {
  local input="$1" out="" index char
  local LC_ALL=C
  for (( index = 0; index < ${#input}; index++ )); do
    char="${input:index:1}"
    case "${char}" in
      [a-zA-Z0-9._~/-]) out="${out}${char}" ;;
      *) out="${out}$(printf '%%%02X' "'${char}")" ;;
    esac
  done
  printf '%s' "${out}"
}

# Copy up to the cap into the world, under names of our own.
#
# Renamed rather than kept for two reasons. A real shoot folder's filenames
# carry the client and the show, and this writes them into a JSON file and into
# whatever terminal the check is being run in (L155). And a name is free to
# hold anything at all, while the ones written here are known to survive being
# turned into a URL.
#
# Sets SEEDED_PHOTO_URLS, the JSON array body the store is written with.
SEEDED_PHOTO_URLS=""
copy_photos_from() {
  local source="$1"
  # Not named `url`: HandCheckLinkTests reads the one `url="` assignment in this
  # file as the link step 4 fires, and refuses when there are two.
  local found taken=0 image extension photo_url
  found="$(images_in "${source}" | wc -l | tr -d ' ')"
  mkdir -p "${PHOTOS}"

  while IFS= read -r image; do
    [[ -z "${image}" ]] && continue
    [[ ${taken} -ge ${SEED_PHOTO_CAP} ]] && break
    taken=$((taken + 1))
    extension="$(printf '%s' "${image##*.}" | tr '[:upper:]' '[:lower:]')"
    cp "${image}" "${PHOTOS}/photo-${taken}.${extension}"
    photo_url="file://$(url_encode_path "${PHOTOS}/photo-${taken}.${extension}")"
    if [[ -z "${SEEDED_PHOTO_URLS}" ]]; then
      SEEDED_PHOTO_URLS="\"${photo_url}\""
    else
      SEEDED_PHOTO_URLS="${SEEDED_PHOTO_URLS}, \"${photo_url}\""
    fi
  done < <(images_in "${source}")

  # Said out loud whenever the cap fired. A cap nobody is told about reads as
  # "it took the whole shoot", and the captions that come back would then be
  # read as the pipeline's opinion of photographs it never saw.
  if [[ ${taken} -lt ${found} ]]; then
    echo "took ${taken} of the ${found} photographs in ${source} (the cap is ${SEED_PHOTO_CAP})"
  else
    echo "took all ${taken} photographs in ${source}"
  fi
}

# One event, at the stage whose screen is the generation screen.
#
# Three fields decide whether the run can be started at all, and each is here
# for a reason rather than for completeness. `stage` because EventDetailView
# shows AssetGenerationView for Photos Assigned and something else for every
# other stage. The day's photos because GenerationScreenBodies disables
# Generate All until there is one. And `ocrResult`, empty but present, because
# PythonBridge.buildManifest throws "No OCR result" before the pipeline is
# started without it: seeding one without it would make the successful half of
# step 6 unreachable while looking exactly like a run that was set up properly.
#
# The program is deliberately thin and obviously invented. It is enough for the
# manifest to be built, and nothing here is a real person.
write_seeded_store() {
  cat > "${STORE}" <<STOREEOF
[
  {
    "id": "6C2F1A44-0000-4000-8000-000000000003",
    "name": "Hand check run",
    "org": "Test Company",
    "venue": "Test Hall",
    "venueContext": "Main Stage",
    "date": ${SEED_DATE_SECONDS},
    "shootType": "Performance",
    "stage": "Photos Assigned",
    "ocrResult": {
      "performers": [
        {"name": "Test Performer One", "role": "soloist", "voice_or_instrument": "piano"},
        {"name": "Test Performer Two", "role": "conductor", "voice_or_instrument": ""}
      ],
      "pieces": [
        {"composer": "Test Composer", "title": "Test Piece", "movements": [], "notes": ""}
      ],
      "program_notes": "A programme invented for the hand check.",
      "organization_notes": "",
      "venue_notes": "",
      "production_details": ""
    },
    "days": {
      "monday": {
        "day": "monday",
        "photoPaths": [${SEEDED_PHOTO_URLS}]
      }
    }
  }
]
STOREEOF
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
    no-code-folder|both-broken|seeded-no-code-folder) project="${NOT_A_CHECKOUT}" ;;
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
shift

# One pass over what is left, because `seeded` takes a path as well as the flag
# and the flag is written after it. An argument that is neither is refused by
# name rather than ignored: a mistyped flag that is silently dropped launches
# the app in the face of somebody who asked for it not to be.
no_launch=0
broken_code_folder=0
photo_source=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) no_launch=1 ;;
    --no-code-folder) broken_code_folder=1 ;;
    *)
      if [[ -z "${photo_source}" ]]; then
        photo_source="$1"
      else
        echo "unexpected argument: $1" >&2
        usage
      fi
      ;;
  esac
  shift
done

case "${command}" in
  healthy|no-code-folder|corrupt-store|unreadable-store|both-broken)
    build_world "${command}"
    echo "built the ${command} world at ${WORLD}"
    if [[ "${no_launch}" == "0" ]]; then
      require_installed
      launch_in "${command}"
    fi
    ;;

  seeded)
    # Checked before the world is touched, so a mistyped path costs nothing.
    require_photo_folder "${photo_source}"
    build_world seeded
    copy_photos_from "${photo_source}"
    write_seeded_store
    state="seeded"
    if [[ "${broken_code_folder}" == "1" ]]; then
      # The failure half of step 6: a run that CAN be started, pointed at a
      # code folder that is not a checkout, so it fails where the pipeline
      # would have run rather than never starting. An event with no photos
      # produces no failure to be told about, which is why this is a flag on
      # the seeded state rather than a state of its own.
      state="seeded-no-code-folder"
      echo "the app will be pointed at ${NOT_A_CHECKOUT}, so a run started here fails"
    fi
    echo "built the ${state} world at ${WORLD}"
    if [[ "${no_launch}" == "0" ]]; then
      require_installed
      launch_in "${state}"
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
