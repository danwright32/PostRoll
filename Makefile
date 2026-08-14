# The one cache location, taken from the shared definition rather than
# spelled here as well (#485). Outside the iCloud-synced checkout.
BUILD_DIR := $(shell . PostRollApp/derived-data-path.sh; printf %s "$$POSTROLL_DERIVED_DATA")
APP_NAME  := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj

.PHONY: install install-force build test test-python test-python-fast check-guards check-toolchain clean

# One build-and-install implementation, not two. This used to run its own
# xcodebuild and cp, skipping the xattr clear, the stable-identity signing and
# the signature verification that build-install.sh added specifically to stop
# macOS re-prompting for Documents access on every rebuild (#83). Installing
# through this target produced an unsigned bundle and reintroduced the prompts.
# build-install.sh runs both test suites before it installs anything (#98), so
# the gate applies to the `postroll` alias too, which calls the script directly
# and never goes through make.
install:
	@./PostRollApp/build-install.sh --launch

install-force:
	@echo "Installing WITHOUT running the tests."
	@SKIP_INSTALL_TESTS=1 ./PostRollApp/build-install.sh --launch

build:
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(APP_NAME)" \
		-configuration Release \
		-derivedDataPath "$(BUILD_DIR)" \
		-destination 'platform=macOS' \
		-quiet \
		build
	@echo "Build complete. Use 'make install' to install a signed, verified bundle."

# The Swift model/service suite. Excludes the UI tests, which drive the real GUI.
test:
	@xcodebuild -project "$(PROJECT)" -scheme PostRollTests \
		-derivedDataPath "$(BUILD_DIR)" -destination 'platform=macOS' test

# The full local suite, in ONE parallel pass (#497).
#
# Safe to run this way because nothing in the suite writes into the checked-out
# source tree any more. That was the whole blocker: the design fingerprint guards
# used to perturb real modules under postroll/media/ and restore them, so a
# worker hashing one of those files mid-perturbation reported a redesign that
# never happened. They now perturb a copy in tmp_path, and tests/conftest.py
# fails any module that writes into the source tree at all, so the property this
# depends on is enforced rather than remembered.
#
# Deliberately no measured timings written here. They were, and a number nobody
# generates or asserts is stale the moment the suite grows, while reading as a
# current fact (L32). `pytest -q` prints the real one at the end of every run.
test-python:
	@venv/bin/python -m pytest tests/ -q -n auto

# The loop between edits: the fast subset alone, for when even three and a half
# minutes is too long to wait on a one line change. Deselects the four files
# that render real reels. pytest prints how many it deselected, so a fast suite
# that has quietly become a run of almost nothing is visible rather than silent
# (#413). On its own this is NOT the gate: `make test-python` and CI run
# everything.
test-python-fast:
	@venv/bin/python -m pytest tests/ -q -m "not slow"

# Proves the registered guard tests still go red on deliberately broken code
# (#416). Not part of `make test`: it mutates the working tree and pays a Swift
# build per entry. Run it whenever a guard is added or changed; for just the
# entries your diff touches, `venv/bin/python tools/check_guards.py --changed`
# (#426). The registry lives in tests/fixtures/guard_mutations/, one file per
# guard (#506), and is held to the code on every normal suite run by
# tests/test_guard_mutation_registry.py.
check-guards:
	@venv/bin/python tools/check_guards.py

# Whether a green build here still means anything (#528). Fails only when THIS
# Mac's Xcode is newer than the one CI is pinned to, because that is the
# direction where locally-clean code can be rejected on a runner and nothing
# here can tell you. Run by build-install.sh before it installs.
check-toolchain:
	@venv/bin/python tools/check_toolchain.py

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared: $(BUILD_DIR)"
