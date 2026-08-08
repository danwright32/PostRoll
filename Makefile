BUILD_DIR := PostRollApp/build
APP_NAME  := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj

.PHONY: install build test test-python clean

# One build-and-install implementation, not two. This used to run its own
# xcodebuild and cp, skipping the xattr clear, the stable-identity signing and
# the signature verification that build-install.sh added specifically to stop
# macOS re-prompting for Documents access on every rebuild (#83). Installing
# through this target produced an unsigned bundle and reintroduced the prompts.
install:
	@./PostRollApp/build-install.sh --launch

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

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared."
