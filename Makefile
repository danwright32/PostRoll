BUILD_DIR := PostRollApp/build
APP_NAME  := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj

.PHONY: install install-force build test test-python test-python-fast check-guards clean

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
	@xcodebuild -project "$(PROJECT)" -scheme PostRollTests -destination 'platform=macOS' test

# The full local suite, in two passes rather than one command (#430).
#
# The slow half is the four files that render real reels, 8m15s of the 9m53s, and
# they are safe to run concurrently: every one writes only into pytest's per-test
# tmp_path, which `test_reference_frames_are_safe_to_parallelise.py` holds true.
# Four workers take them from 495s to 221s.
#
# The rest stays serial, because the suite as a whole is NOT parallel-safe and
# this was measured rather than assumed: `pytest tests/ -n auto` fails on
# 2026-08-13, because `test_media_design_fingerprint.py` perturbs real files under
# `postroll/media/` and restores them, so a worker hashing those same files while
# the perturbation is in place reads it and reports a template redesign that
# never happened. Flake that reproduces on nobody's machine is worse than a slow
# suite, so the fast half is left alone until that is fixed (#497).
#
# It runs first on purpose: a break in the ordinary tests is worth hearing about
# in 100 seconds rather than after the reels have rendered.
test-python: test-python-fast
	@venv/bin/python -m pytest tests/ -q -m slow -n auto

# The loop between edits, and the first pass of the full run above, so there is
# one spelling of it rather than two that can disagree. Deselects the four files
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
# (#426). The registry lives in tests/fixtures/guard_mutations.json and is held
# to the code on every normal suite run by tests/test_guard_mutation_registry.py.
check-guards:
	@venv/bin/python tools/check_guards.py

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared."
