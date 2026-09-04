#!/usr/bin/env bash
# Which Python interpreter this checkout's tooling runs on (#960).
#
# `venv/` is gitignored, so it exists in the PRIMARY checkout and nowhere else.
# A git worktree has none, and `venv/bin/python` there is "no such file or
# directory", which left the Python half of the suite unrunnable from a
# worktree: the only way through was to type another checkout's interpreter as
# an absolute path.
#
# That matters because working in a worktree is what keeps one session from
# editing the primary checkout underneath another, which is exactly what broke
# an app update on 2026-08-29 (#956, #957). A workflow that only half works is
# one people stop using.
#
# Resolved through git's COMMON dir, the same way hooks/lib/issue-spool.sh
# resolves a worktree back to the checkout it belongs to: a worktree's common
# dir is the primary checkout's `.git`, so its parent is the checkout holding
# the venv. Defined once, here, because the Makefile and anything else that
# needs an interpreter both want the same answer and two spellings of one
# location is how they come to disagree (#485, L41).
#
# It never falls back to a system `python3`. That interpreter has none of the
# pinned dependencies, so the suite would fail on an import and report a
# missing PACKAGE rather than a missing virtualenv, which sends the reader
# somewhere the problem is not (L11). A refusal that names both places it
# looked is the useful answer.
#
# Sourced, not run: `. ./venv-python.sh` then read POSTROLL_PYTHON. Takes the
# checkout directory as an optional first argument so it can be tested against
# a directory other than the caller's own.

_postroll_venv_root="${1:-$PWD}"

_postroll_venv_common="$(git -C "${_postroll_venv_root}" rev-parse \
  --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "${_postroll_venv_common}" ] && [ -d "${_postroll_venv_common}" ]; then
  _postroll_venv_primary="$(dirname "${_postroll_venv_common}")"
else
  # Not a git checkout at all, or a git too old for --path-format. Either way
  # the only place left to look is where we are, and saying so is better than
  # guessing at a sibling directory.
  _postroll_venv_primary="${_postroll_venv_root}"
fi

# This checkout first. A worktree that has been given its own venv is using it
# deliberately, and quietly preferring another checkout's would run the tests
# against dependencies nobody here installed.
POSTROLL_PYTHON=""
for _postroll_venv_candidate in \
    "${_postroll_venv_root}/venv/bin/python" \
    "${_postroll_venv_primary}/venv/bin/python"; do
  if [ -x "${_postroll_venv_candidate}" ]; then
    POSTROLL_PYTHON="${_postroll_venv_candidate}"
    break
  fi
done

if [ -z "${POSTROLL_PYTHON}" ]; then
  # Named as a missing VIRTUALENV, with both places it looked, so the reader is
  # sent to the checkout that should hold one rather than to whatever the next
  # command happens to fail on.
  echo "no PostRoll virtualenv found: looked in" \
       "${_postroll_venv_root}/venv/bin/python and" \
       "${_postroll_venv_primary}/venv/bin/python." \
       "Create one in the primary checkout with" \
       "\`python3 -m venv venv && venv/bin/pip install -r requirements.txt\`;" \
       "every worktree of it then shares that one." >&2
  # Still the primary candidate, so whatever runs next fails naming the path
  # that is meant to exist rather than with an empty command line.
  POSTROLL_PYTHON="${_postroll_venv_primary}/venv/bin/python"
fi

export POSTROLL_PYTHON
unset _postroll_venv_root _postroll_venv_common _postroll_venv_primary \
      _postroll_venv_candidate
