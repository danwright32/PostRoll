BUILD_DIR := PostRollApp/build
APP_NAME  := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj

.PHONY: install install-force build test test-python test-python-fast clean

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

test-python:
	@venv/bin/python -m pytest tests/ -q

# The loop between edits. Deselects the four files that render real reels, which
# are 8m15s of the full 9m53s. pytest prints how many it deselected, so a fast
# suite that has quietly become a run of almost nothing is visible rather than
# silent (#413). This is NOT the gate: `make test-python` and CI run everything.
test-python-fast:
	@venv/bin/python -m pytest tests/ -q -m "not slow"

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared."
