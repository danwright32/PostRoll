# The one cache location, taken from the shared definition rather than
# spelled here as well (#485). Outside the iCloud-synced checkout.
BUILD_DIR := $(shell . PostRollApp/derived-data-path.sh; printf %s "$$POSTROLL_DERIVED_DATA")

# One build at a time against that cache (#642). Since #621 the guard sweep
# builds into it too, and two xcodebuilds against one DerivedData produce errors
# that read like real compile failures in whichever run notices first. Sessions
# run side by side on this machine, and a sweep holds the cache for 20+ minutes.
#
# Beside the cache rather than named separately, so the lock cannot end up
# guarding a different location from the one being shared. tools/check_guards.py
# derives the same path from the same definition.
BUILD_LOCK := $(BUILD_DIR).lock
# Through Python rather than flock(1), which is a Linux tool present here only
# because Homebrew installed it: a Makefile calling it would fail on any
# checkout without that package. tools/check_guards.py takes the same lock at
# the same path, so there is one implementation rather than two.
LOCKED = /usr/bin/env python3 tools/with_build_lock.py
APP_NAME  := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj

.PHONY: install install-force build test test-python test-python-fast \
	check-guards check-toolchain record-fingerprints record-test-durations \
	record-design-change review-sheet clean

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
	@$(LOCKED) xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(APP_NAME)" \
		-configuration Release \
		-derivedDataPath "$(BUILD_DIR)" \
		-destination 'platform=macOS' \
		-quiet \
		build
	@echo "Build complete. Use 'make install' to install a signed, verified bundle."

# The three tests that RENDER rather than check, named once so the sheet can
# select them and the ordinary suite can skip them (#644).
REVIEW_TESTS := \
	PostRollTests/BannerLegibilityTests/testDumpBannersForReview \
	PostRollTests/HostedControlLegibilityTests/testDumpEveryMeasuredScreenForReview \
	PostRollTests/PhotoLightboxTests/testDumpTheLightboxForReview

# The Swift model/service suite. Excludes the UI tests, which drive the real GUI,
# and the three screenshot dumps.
#
# The dumps are skipped because they are not checks, they are a rendering, and
# rendering them here CONSUMED the thing `make review-sheet` compares against
# (#644). The dump clears the sheet folder and keeps what was there as the
# baseline, so the ordinary order of work (render the sheet, change something,
# run the suite, look at the sheet) rotated the POST-change pictures into the
# baseline and the comparison then reported nothing had moved. A comparison that
# reports no difference because its reference point was overwritten is worse
# than no comparison.
#
# Skipped from the same REVIEW_TESTS list the sheet selects, so the two cannot
# drift into disagreeing about which tests are renderings (L41). CI runs
# xcodebuild directly rather than through here, so the dumps are still proven
# there on every push; what is skipped is only the local rendering.
test:
	@$(LOCKED) xcodebuild -project "$(PROJECT)" -scheme PostRollTests \
		-derivedDataPath "$(BUILD_DIR)" -destination 'platform=macOS' \
		$(foreach t,$(REVIEW_TESTS),-skip-testing:$(t)) \
		test

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

# The loop between edits: the fast subset alone, for when even two minutes is too
# long to wait on a one line change. Deselects the files measured above the floor
# in tests/file_durations.py, which since #766 is three of them rather than the
# eight the reference-frames matrix happened to name. pytest prints how many it
# deselected, so a fast suite that has quietly become a run of almost nothing is
# visible rather than silent (#413). On its own this is NOT the gate:
# `make test-python` and CI run everything.
#
# `-n auto` since #766, which is a plain oversight corrected: the full target has
# always been parallel and this one never was. It matters more now, because the
# measured set is three files rather than the eight the matrix named, so the fast
# run carries five more files than it did. Measured on this Mac on 2026-08-21:
# 138s serial against 34.7s with the workers, on the same 3168 tests.

test-python-fast:
	@venv/bin/python -m pytest tests/ -q -m "not slow" -n auto

# Re-measure what each test file costs, which is what decides the set above. Run
# it after adding a file heavy enough to belong to the full run only; a file's
# cost does not drift on its own, so nothing else needs it (#766).
record-test-durations:
	@venv/bin/python tools/record_test_durations.py

# Proves the registered guard tests still go red on deliberately broken code
# (#416). Not part of `make test`: it mutates the working tree, and each entry
# recompiles the file it perturbs plus everything downstream of it, so the cost
# is per entry however warm the cache is. Measured on this Mac with the cache
# warm: about 12s for an entry in a leaf file and about 22s for one in
# PaintedSurfaces.swift, which most of the app imports.
#
# It builds into the same BUILD_DIR as everything else (#621), so it starts from
# whatever the last `make build` or `make test` left rather than from a second
# copy of DerivedData that only this target ever filled and `make clean` could
# not name.
#
# Run it whenever a guard is added or changed; for just the entries your diff
# touches, `venv/bin/python tools/check_guards.py --changed` (#426). The
# registry lives in tests/fixtures/guard_mutations/, one file per guard (#506),
# and is held to the code on every normal suite run by
# tests/test_guard_mutation_registry.py.
check-guards:
	@venv/bin/python tools/check_guards.py

# Whether a green build here still means anything (#528). Fails only when THIS
# Mac's Xcode is newer than the one CI is pinned to, because that is the
# direction where locally-clean code can be rejected on a runner and nothing
# here can tell you. Run by build-install.sh before it installs.
check-toolchain:
	@venv/bin/python tools/check_toolchain.py

# The only supported way to record a media design fingerprint (#660).
#
# The design fingerprint guard fails whenever a template's source moves, and
# offers two ways out: bump the design version because the rendering changed, or
# record the fingerprint alone because it did not. Only the first was ever
# implemented, so the second was done with a script written on the spot, which
# cannot tell those two apart. That is the whole thing the guard exists to ask.
#
# This runs the reference frames that photograph each moved template and records
# only what they vouch for. It renders real reels, so it is not fast, and it
# refuses rather than guessing: see the tool's docstring for every case.
record-fingerprints:
	@venv/bin/python tools/record_design_fingerprints.py

# A picture of every screen the checks measure, in one folder (#623).
#
# Reviewing a visual change used to mean launching the app and navigating to
# each screen. The suite already rendered all of these, several times over, and
# threw the pixels away: #611 changed the colour of type in fourteen places
# across three screens and the only review available was by hand.
#
# One xcodebuild invocation on purpose. The three dump tests write into one
# folder that is emptied once per process, so running them separately would have
# each clear the others' work.
#
# The previous run is kept as a baseline so a visual change reports itself
# (#636). It says only that a screen CHANGED: a recorded expectation defends
# whatever it captured, including a state nobody checked (L84), so whether a
# screen is CORRECT stays the business of the ink and footprint checks.
#
# The folder is NOT named here. The tests decide it and print it, and this reads
# it back, because a path both sides spell separately is a path they can
# disagree about (L41). Every step that could match nothing is checked, since a
# grep that finds nothing exits quietly and would leave this reporting a sheet
# that was never written (L100).
#
# Including the specs themselves. Measured while writing this: renaming one of
# the three to a test that does not exist left xcodebuild reporting TEST
# SUCCEEDED, and this target cheerfully announced 80 images with the whole
# lightbox group absent. A spec matching nothing is not a pass (L98), so the
# count of groups that reported is held to the count of tests asked for.


review-sheet:
	out=$$($(LOCKED) xcodebuild -project "$(PROJECT)" -scheme PostRollTests \
		-derivedDataPath "$(BUILD_DIR)" -destination 'platform=macOS' \
		$(foreach t,$(REVIEW_TESTS),-only-testing:$(t)) \
		test 2>&1); \
	if ! printf '%s' "$$out" | grep -q 'TEST SUCCEEDED'; then \
		printf '%s\n' "$$out" | grep -E 'error:|failed' | tail -20; \
		echo "The render run failed, so there is no sheet to review."; \
		exit 1; \
	fi; \
	groups=$$(printf '%s\n' "$$out" | grep -c '^REVIEW-SHEET-WROTE ' || true); \
	if [ "$$groups" -ne $(words $(REVIEW_TESTS)) ]; then \
		echo "$$groups of $(words $(REVIEW_TESTS)) dumps reported. A test spec that"; \
		echo "matches nothing still exits green, so a sheet missing a whole group"; \
		echo "looks exactly like a full one. Check the names in REVIEW_TESTS."; \
		exit 1; \
	fi; \
	folder=$$(printf '%s\n' "$$out" | sed -n 's/^REVIEW-SHEET-FOLDER //p' | head -1); \
	if [ -z "$$folder" ]; then \
		echo "The run passed but never said where it wrote. Nothing here can"; \
		echo "point at a sheet, and an empty answer must not read as an empty"; \
		echo "folder: check ReviewSheet.folderMarker still prints."; \
		exit 1; \
	fi; \
	count=$$(ls "$$folder" 2>/dev/null | grep -c '\.png$$' || true); \
	if [ "$$count" -eq 0 ]; then \
		echo "No images in $$folder, so there is nothing to review."; \
		exit 1; \
	fi; \
	printf '%s\n' "$$out" | sed -n 's/^REVIEW-SHEET-WROTE /  /p'; \
	echo "  $$count images in $$folder"; \
	prev=$$(printf '%s\n' "$$out" | sed -n 's/^REVIEW-SHEET-BASELINE //p' | head -1); \
	if [ -z "$$prev" ]; then \
		echo "  the run never said where the previous sheet was kept, so nothing"; \
		echo "  here can say what moved: check ReviewSheet.baselineMarker"; \
		exit 1; \
	fi; \
	if [ ! -d "$$prev" ]; then \
		echo "  no previous sheet to compare against, so this run is the baseline"; \
	else \
		moved=0; added=0; gone=0; \
		for f in "$$folder"/*.png; do \
			b="$$prev/$$(basename "$$f")"; \
			if [ ! -f "$$b" ]; then \
				added=$$((added+1)); echo "    new:     $$(basename "$$f")"; \
			elif ! cmp -s "$$f" "$$b"; then \
				moved=$$((moved+1)); echo "    changed: $$(basename "$$f")"; \
			fi; \
		done; \
		for b in "$$prev"/*.png; do \
			[ -f "$$folder/$$(basename "$$b")" ] || { \
				gone=$$((gone+1)); echo "    gone:    $$(basename "$$b")"; }; \
		done; \
		echo "  $$moved of $$count changed, $$added new, $$gone gone"; \
	fi; \
	open "$$folder" || true

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared: $(BUILD_DIR)"


# The one supported way to record a DELIBERATE design change (#786).
#
# Changing what a template renders takes several steps that only work in one
# order, and the tools refuse when it is wrong, correctly, but each refusal costs
# a re-run of a suite that takes minutes. On 2026-08-20 it was done five times
# and the order was wrong twice.
#
# This checks the version bump has been made, regenerates the shared design stamp
# from its writer, re-records the reference frames, and then STOPS, handing back
# the frames that moved. Looking at them is the step nothing downstream can do
# for you: the re-record flag is the single way a broken frame becomes the
# expectation. Commit them, then `make record-fingerprints`, which refuses to
# vouch for a frame with uncommitted changes and is what makes the order matter.
#
# The other door is `make record-fingerprints` on its own, for a change that
# moved a template's source without moving a pixel. This refuses, by name, when
# that is the case it is looking at.
record-design-change:
	@venv/bin/python tools/record_design_change.py
