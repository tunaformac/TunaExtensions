ARCH := $(shell uname -m)
# One scheme per extension project. GitHubExtension's target kept its
# load-bearing TunaGitHub name; resolve-extension-scheme maps either spelling.
EXTENSION_SCHEMES := BrewExtension CleanShotExtension TunaGitHub NotesExtension NotionExtension ObsidianExtension RemindersExtension SafariExtension ThingsExtension
DESTINATION := generic/platform=macOS
DEV_DESTINATION := platform=macOS,arch=$(ARCH)
DERIVED_DATA := ./build/dd
INSTALL_DIR := $(HOME)/Library/Application Support/Tuna/ExtensionsDev

.DEFAULT_GOAL := build-all
.PHONY: build-all ext ext-all ext-package ext-upload ext-upload-all ext-release clean

define require_target
	@test -n "$(TARGET)" || { echo "usage: make $@ TARGET=<Scheme>" >&2; exit 64; }
endef

# Compile every extension in Release.
build-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; scripts/build-extension-product.sh "$$SCHEME" Release "$(DESTINATION)" "$(DERIVED_DATA)" >/dev/null; done; echo "All extensions build."

# Build one extension and install it into Tuna's ExtensionsDev for local development.
ext:
	$(require_target)
	@scripts/install-extension-product.sh "$(TARGET)" "$(INSTALL_DIR)" Debug "$(DEV_DESTINATION)" "$(DERIVED_DATA)"

# Dev-install every extension.
ext-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do scripts/install-extension-product.sh "$$SCHEME" "$(INSTALL_DIR)" Debug "$(DEV_DESTINATION)" "$(DERIVED_DATA)"; done

# Build + package one extension as a .tunaextension store artifact.
# Needs a Tuna binary for the declaration dump: /Applications/Tuna.app or TUNA_BINARY.
ext-package:
	$(require_target)
	@scripts/ext-package.sh "$(TARGET)" "$(DESTINATION)" "$(DERIVED_DATA)"

# Build + upload one extension to the store API.
ext-upload:
	$(require_target)
	@scripts/upload-extension.sh "$(TARGET)"

# Build + upload all extensions.
ext-upload-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; scripts/upload-extension.sh "$$SCHEME"; done

# Build + upload one extension, then tag the release commit.
ext-release:
	$(require_target)
	@scripts/release-extension.sh "$(TARGET)"

clean:
	rm -rf ./build/dd
