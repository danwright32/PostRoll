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

.PHONY: install install-force build test test-swift test-python \
	test-python-fast \
	check-guards check-toolchain record-fingerprints record-test-durations \
	build-gui-tests \
	record-design-change record-codec-change review-sheet collage-arrangements clean

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

# Compile the GUI test target without running it.
#
# `make test` builds the PostRollTests scheme, which does not contain
# PostRollUITests at all, so nothing local ever compiles the GUI tests and the
# first thing that does is a runner. That is how a concurrency-safety error
# reached CI on 2026-08-23 and failed a dispatched run at the build step (#864).
#
# build-for-testing rather than test: compiling is the part no local check had,
# and RUNNING it would launch the app over whatever is on screen.
build-gui-tests:
	@$(LOCKED) xcodebuild build-for-testing -project "$(PROJECT)" \
		-scheme PostRollUITests \
		-derivedDataPath "$(BUILD_DIR)" -destination 'platform=macOS' \
		-quiet

# Every test this project has, both halves, each saying how many it ran (#932).
#
# This target used to be the Swift suite alone. Nothing in the name said so and
# it printed no summary separating the two, so a green `make test` read as the
# whole suite passing while roughly 4000 Python tests had never been started. It
# misled twice, once badly enough to be written into this project's notes.
#
# Sequential through $(MAKE) rather than as prerequisites, because prerequisites
# can be dealt out to workers under `make -j` and these two legs both want the
# whole machine, and the Swift one takes the shared build lock while it has it.
#
# The counts are the point. Both runners exit 0 on a run that executed NOTHING:
# `pytest -k <no match>` prints "no tests ran", and xcodebuild reports TEST
# SUCCEEDED for a spec that matched nothing (#644). So each leg reads its own
# transcript back and refuses when the total is missing or zero, which is the
# only thing that tells a full run from a half one (L98).
test:
	@$(MAKE) --no-print-directory test-swift
	@$(MAKE) --no-print-directory test-python

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
#
# Wrapped in tools/suite_counts.py, which streams the output straight through
# and reads the executed-tests total off the end of it. The wrapper decides only
# whether the suite was REACHED; xcodebuild's own exit code still decides
# whether it was green, because one field answering both questions is how a run
# of nothing came to read as a full suite (L53).
# Where the executed-test count is read from since #992, because a parallel run
# does not print one. Under the build directory so `make clean` takes it.
SWIFT_RESULTS := $(BUILD_DIR)/swift-suite.xcresult

# -parallel-testing-enabled here and in .github/workflows/swift.yml, and in
# neither case in the SCHEME. Measured 2026-08-30: the flag alone parallelises
# with the scheme still saying parallelizable="NO", and keeping it out of the
# scheme is what leaves `tools/check_guards.py` alone. That prover runs ONE test
# at a time to watch it go red, parallelism means nothing to it, and it reads
# the `Executed N tests` line the scheme setting would have taken away from all
# 60-odd of its Swift entries.
#
# -parallel-testing-worker-count from this machine's own core count, computed
# rather than written down so the laptop and the runner each get their own.
#
# Not left to xcodebuild's default: measured on the runner 2026-08-30, that
# default was TWO worker processes, whatever the core count was.
#
# tests/test_both_swift_runners_agree.py holds this target and the CI step to
# the same flags, so local and CI cannot disagree about what they ran (L41).
test-swift:
	@venv/bin/python tools/suite_counts.py run swift \
		--result-bundle "$(SWIFT_RESULTS)" -- \
		$(LOCKED) xcodebuild -project "$(PROJECT)" -scheme PostRollTests \
		-derivedDataPath "$(BUILD_DIR)" -destination 'platform=macOS' \
		-resultBundlePath "$(SWIFT_RESULTS)" \
		-parallel-testing-enabled YES \
		-parallel-testing-worker-count $(shell sysctl -n hw.ncpu) \
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
	@venv/bin/python tools/suite_counts.py run python -- \
		venv/bin/python -m pytest tests/ -q -n auto

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

# Re-measure what each test file costs, which is what decides the set above.
#
# Prefer `--add` for a NEW file, which is what #1058 asks a branch for. A full
# re-record re-reads every file and re-derives every share, and the shares move
# with the machine's load rather than with the tests: one on 2026-08-30 moved
# the total 31.7% and unevenly, carrying a file across the expensive floor and
# turning a guard red on a suite nobody had changed (#1038).
#
#     venv/bin/python tools/record_test_durations.py --add tests/test_new.py
#
# That measures the new file beside seven files already in the record, in one
# run, scales the reading onto the record's own run by the median of their
# ratios, and writes down which run it came from and the scale it used. The
# files already in the record keep the readings they had.
#
# The full re-record below is for when the record has drifted as a whole, and it
# wants an idle machine. `tests/test_fast_subset_stays_honest.py` says when: it
# goes red once most of the record has been scaled on from elsewhere rather than
# measured in one run.
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


# Every collage arrangement the chooser could hand over, drawn (#923).
#
# The phone chrome overlay in the app shows the collage that WAS rendered, so it
# answers "is this frame safe" and cannot answer "is every arrangement the
# chooser might give me safe". That is how #921 shipped: the collage on screen
# looked fine and the one burying three of seven photographs was one press of
# New layout away.
#
# This draws the pool instead, rejected arrangements included, because a sheet
# of survivors looks exactly like a filter that rejects nothing.
collage-arrangements:
	@venv/bin/python tools/render_collage_arrangements.py \
		--out "$(BUILD_DIR)/collage-arrangements" $(if $(COUNT),--count $(COUNT),)

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

# The third door (#818): the pixels moved and the design did not.
#
# #811 dropped one encode argument and moved 0.27% of the clip reel's pixels,
# which fails the reference frame while the two frames are indistinguishable
# side by side. `record-fingerprints` refuses, correctly, and the only door left
# was a version bump, which badges every cached asset of that template as out of
# date for a change nobody can see (L36).
#
# This judges the SHAPE of what moved, off the readings the comparisons already
# take, and re-records only what reads as an encoder rounding rather than as an
# element moved or redrawn. It writes no version and no fingerprint: it hands
# the frames back to be looked at, and `record-fingerprints` records them once
# they are committed and passing.
record-codec-change:
	@venv/bin/python tools/record_codec_change.py
