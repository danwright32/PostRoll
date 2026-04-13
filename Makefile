BUILD_DIR := /tmp/PostRoll-build
APP_NAME  := PostRoll
SCHEME    := PostRoll
PROJECT   := PostRollApp/PostRoll.xcodeproj
INSTALL   := /Applications/$(APP_NAME).app

.PHONY: install build clean

install: build
	@echo "Installing $(APP_NAME).app to /Applications…"
	@rm -rf "$(INSTALL)"
	@cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app" "$(INSTALL)"
	@echo "Done. Launch PostRoll from Spotlight or /Applications."

build:
	@echo "Building $(APP_NAME) (Release)…"
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-derivedDataPath "$(BUILD_DIR)" \
		-quiet \
		build
	@echo "Build complete."

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Build cache cleared."
