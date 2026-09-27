#!/usr/bin/env bash
# Run the toolchain check for an install, and warn rather than refuse when the
# only problem is this Mac's newer Xcode (#1441).
#
# Sourced by build-install.sh. Its own file so the tests can drive it with a
# stand-in check instead of this Mac's real Xcode.
#
# tools/check_toolchain.py exits 3 when Xcode is ahead of CI's pin and nothing
# else is wrong. That refused every install while CI could not move to the
# newer Xcode (#1419), and the only way through, SKIP_INSTALL_TESTS=1, skipped
# the whole Python gate too. Dan, 2026-09-27: warn, don't block. Any other
# failure still refuses.

# toolchain_gate <check command...>
#
# Returns 0 to go on and 1 to refuse. Sets XCODE_AHEAD=1 when it went on past a
# newer Xcode, so the installer can say so again once it has finished, and adds
# the machine test making the same comparison to PYTEST_ADDOPTS as a deselect.
toolchain_gate() {
  local rc=0
  "$@" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    3)
      XCODE_AHEAD=1
      # The install's own Python run includes the same comparison as a test,
      # which would refuse the install the gate has just let through. Waived
      # once, waived there too, and nothing else is skipped (#1441).
      export PYTEST_ADDOPTS="${PYTEST_ADDOPTS:+${PYTEST_ADDOPTS} }--deselect tests/test_toolchain_matches_ci.py::test_this_machine_is_not_ahead_of_the_compiler_ci_will_use"
      {
        echo "WARNING: this Mac's Xcode is newer than the one CI builds with, so"
        echo "         code that builds here can still be refused by CI. Installing"
        echo "         anyway (#1441); the tests below still decide."
      } >&2
      return 0
      ;;
    *) return 1 ;;
  esac
}
