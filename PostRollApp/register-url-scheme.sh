#!/usr/bin/env bash
set -euo pipefail

# Make the INSTALLED copy of PostRoll the one macOS hands a postroll:// link to
# (#840).
#
# When #840 was filed, LaunchServices held 14 registrations for PostRoll.app:
# build products under two DerivedData roots, copies under paths the project has
# not lived at since it moved in August 2026, two under /private/tmp, and the
# installed one. That cost nothing while PostRoll answered no URLs. Declaring
# the scheme makes every one of them a candidate, and macOS picks by rules this
# repo does not get a vote in. A Debug build answering the link reads and writes
# its own events store, so the event Dan creates is simply not in the app he
# normally opens.
#
# This narrows the field. It does NOT prove the right copy won: nothing here
# can, because the choice is made later and elsewhere. What proves it is firing
# a real link and reading which PID came to the front, and, durably, the warning
# the app itself shows when the copy answering a link is not this one
# (`AnsweringCopy` in Swift). Two halves, because a tidy database goes stale the
# next time anything builds.
#
# Run by build-install.sh after it installs. Safe to run by hand at any time.
#
# Seams, both used by tests/test_url_scheme_registrations.py:
#   POSTROLL_LS_DUMP_FILE   read the registration dump from a file instead of
#                           asking LaunchServices for it
#   POSTROLL_LS_DRY_RUN=1   print what would be run, run nothing

INSTALLED="/Applications/PostRoll.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

run() {
  if [[ "${POSTROLL_LS_DRY_RUN:-0}" == "1" ]]; then
    echo "WOULD: $*"
  else
    "$@"
  fi
}

if [[ "${POSTROLL_LS_DRY_RUN:-0}" != "1" && ! -x "${LSREGISTER}" ]]; then
  echo "Error: ${LSREGISTER} is not there, so nothing can be told which copy of" >&2
  echo "       PostRoll answers a postroll:// link." >&2
  exit 1
fi

if [[ "${POSTROLL_LS_DRY_RUN:-0}" != "1" && ! -d "${INSTALLED}" ]]; then
  echo "Error: ${INSTALLED} does not exist, so there is no installed copy to" >&2
  echo "       point links at. Run ./build-install.sh first." >&2
  exit 1
fi

# Registered FIRST, so the check below can insist on finding it. A sweep that
# ran before this would have no way to tell "LaunchServices does not know about
# the installed copy" from "the dump is being read wrong".
echo "==> Registering ${INSTALLED}"
run "${LSREGISTER}" -f "${INSTALLED}"

if [[ -n "${POSTROLL_LS_DUMP_FILE:-}" ]]; then
  DUMP="$(cat "${POSTROLL_LS_DUMP_FILE}")"
else
  DUMP="$("${LSREGISTER}" -dump)"
fi

# The dump's path lines look like:
#   path:                 /Applications/PostRoll.app (0x105f8)
# Matched on the whole bundle name so a different application whose name merely
# contains ours is not swept up with it.
REGISTERED="$(printf '%s\n' "${DUMP}" \
  | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*PostRoll\.app\) (0x[0-9a-f]*)$/\1/p' \
  | sort -u || true)"

if [[ -z "${REGISTERED}" ]]; then
  echo "Error: no PostRoll.app is registered with LaunchServices at all, not even" >&2
  echo "       the copy this script just registered. That means the dump is being" >&2
  echo "       read wrong, not that the database is tidy: reporting a clean sweep" >&2
  echo "       here would be finding nothing and calling it success." >&2
  exit 1
fi

if ! printf '%s\n' "${REGISTERED}" | grep -qxF "${INSTALLED}"; then
  echo "Error: ${INSTALLED} is not among the registered copies, which are:" >&2
  printf '         %s\n' ${REGISTERED} >&2
  echo "       It was registered a moment ago, so either that silently did" >&2
  echo "       nothing or these paths are being read wrong. Either way a link" >&2
  echo "       would reach one of the copies above instead." >&2
  exit 1
fi

SWEPT=0
while IFS= read -r COPY; do
  [[ -z "${COPY}" ]] && continue
  [[ "${COPY}" == "${INSTALLED}" ]] && continue
  echo "==> Unregistering ${COPY}"
  # Not fatal. A registration for a bundle that is no longer on disk can refuse
  # to be removed, and that is worth saying rather than worth stopping for.
  if ! run "${LSREGISTER}" -u "${COPY}"; then
    echo "    Could not unregister it. It may still be offered the link." >&2
  fi
  SWEPT=$((SWEPT + 1))
done <<< "${REGISTERED}"

echo "==> ${SWEPT} other PostRoll.app registration(s) cleared; ${INSTALLED} is registered."
echo "    Which copy macOS actually hands a link to is still its decision. PostRoll"
echo "    says so itself when a link reaches a copy that is not the installed one."
