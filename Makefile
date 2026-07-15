ARCH := $(shell uname -m)
# One scheme per extension project. GitHubExtension's target kept its
# load-bearing TunaGitHub name; resolve-extension-scheme maps either spelling.
EXTENSION_SCHEMES := BrewExtension CleanShotExtension TunaGitHub NotesExtension NotionExtension ObsidianExtension RemindersExtension SafariExtension ThingsExtension
DESTINATION := generic/platform=macOS
DEV_DESTINATION := platform=macOS,arch=$(ARCH)
DERIVED_DATA := ./build/dd
INSTALL_DIR := $(HOME)/Library/Application Support/Tuna/ExtensionsDev

.DEFAULT_GOAL := build-all
.PHONY: build-all test test-tooling ext ext-all ext-package ext-upload ext-upload-all ext-release clean

define require_target
	@test -n "$(TARGET)" || { echo "usage: make $@ TARGET=<Scheme>" >&2; exit 64; }
endef

# Compile every extension in Release.
build-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; ./scripts/tuna-extension build --scheme "$$SCHEME" --release >/dev/null; done; echo "All extensions build."

# Exercise release tooling, then discover every extension unit-test target.
# Require each shared scheme to cover every test target in its project.
test: test-tooling
	@set -e; found_tests=""; \
	for PBXPROJ in */*.xcodeproj/project.pbxproj; do \
		grep -q 'com.apple.product-type.bundle.unit-test' "$$PBXPROJ" || continue; \
		found_tests=1; \
		PROJECT="$${PBXPROJ%/project.pbxproj}"; \
		PROJECT_NAME="$$(basename "$$PROJECT" .xcodeproj)"; \
		RESOLVED="$$(./scripts/resolve-extension-scheme.sh "$$PROJECT_NAME")"; \
		SCHEME="$$(printf '%s\n' "$$RESOLVED" | cut -f2)"; \
		./scripts/verify-test-scheme.sh "$$PBXPROJ" "$$PROJECT/xcshareddata/xcschemes/$$SCHEME.xcscheme"; \
		echo "=== $$SCHEME tests ==="; \
		xcodebuild test -project "$$PROJECT" -scheme "$$SCHEME" -configuration Debug -destination "$(DEV_DESTINATION)" -derivedDataPath "$(DERIVED_DATA)/tests/$$SCHEME" CODE_SIGNING_ALLOWED=NO; \
	done; \
	test -n "$$found_tests" || { echo "No extension unit-test targets found." >&2; exit 1; }; \
	echo "All extension tests pass."

test-tooling:
	@./tests/release-tooling.sh

# Build one extension and install it into Tuna's ExtensionsDev for local development.
ext:
	$(require_target)
	@./scripts/tuna-extension install --scheme "$(TARGET)"

# Dev-install every extension.
ext-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do ./scripts/tuna-extension install --scheme "$$SCHEME"; done

# Build + package one extension as a .tunaextension store artifact.
# Needs a Tuna binary for the declaration dump: /Applications/Tuna.app or TUNA_BINARY.
ext-package:
	$(require_target)
	@./scripts/tuna-extension package --scheme "$(TARGET)"

# Build + upload one extension to the store API.
ext-upload:
	$(require_target)
	@./scripts/tuna-extension upload --scheme "$(TARGET)"

# Build + upload all extensions.
ext-upload-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do \
		echo "=== $$SCHEME ==="; \
		./scripts/tuna-extension upload --scheme "$$SCHEME"; \
	done

# Build + upload one extension, then tag the release commit.
ext-release:
	$(require_target)
	@./scripts/tuna-extension release --scheme "$(TARGET)"

clean:
	rm -rf ./build/dd
