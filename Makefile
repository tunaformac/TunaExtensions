ARCH := $(shell uname -m)
# One scheme per extension project. GitHubExtension's target kept its
# load-bearing TunaGitHub name; resolve-extension-scheme maps either spelling.
EXTENSION_SCHEMES := ArenaExtension BrewExtension CleanShotExtension FancyTextExtension TunaGitHub MyMindExtension NotesExtension NotionExtension ObsidianExtension PoofExtension RemindersExtension SafariExtension ThingsExtension
DESTINATION := generic/platform=macOS
DEV_DESTINATION := platform=macOS,arch=$(ARCH)
DERIVED_DATA := ./build/dd
INSTALL_DIR := $(HOME)/Library/Application Support/Tuna/ExtensionsDev
TUNA_ROOT ?= ../Tuna
LOCAL_DERIVED_DATA := ./build/dd-local

.DEFAULT_GOAL := build-all
.PHONY: build-all test test-release-scripts test-extensions ext ext-all ext-local ext-all-local ext-package ext-upload release release-all clean

define require_target
	@test -n "$(TARGET)" || { echo "usage: make $@ TARGET=<Scheme>" >&2; exit 64; }
endef

# Compile every extension in Release.
build-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; ./scripts/tuna-extension build --scheme "$$SCHEME" --release >/dev/null; done; echo "All extensions build."

# Run release tooling regressions and every extension unit-test target.
test: test-release-scripts test-extensions

test-release-scripts:
	@./tests/release-all-extensions-test.sh

test-extensions:
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

# Build one extension and install it into Tuna's ExtensionsDev for local development.
ext:
	$(require_target)
	@./scripts/tuna-extension install --scheme "$(TARGET)"

# Dev-install every extension.
ext-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do ./scripts/tuna-extension install --scheme "$$SCHEME"; done

# Build one extension against Tuna's local TunaKit source and dev-install it.
ext-local:
	$(require_target)
	@set -e; \
	PACKAGE="$$(./scripts/prepare-local-tunakit-package.sh "$(TUNA_ROOT)")"; \
	TUNA_LOCAL_TUNAKIT_PACKAGE="$$PACKAGE" \
	  ./scripts/install-local-extension-product.sh "$(TARGET)" "$(INSTALL_DIR)" "$(LOCAL_DERIVED_DATA)"

# Build every extension against Tuna's local TunaKit source and dev-install it.
ext-all-local:
	@set -e; \
	PACKAGE="$$(./scripts/prepare-local-tunakit-package.sh "$(TUNA_ROOT)")"; \
	for SCHEME in $(EXTENSION_SCHEMES); do \
	  TUNA_LOCAL_TUNAKIT_PACKAGE="$$PACKAGE" \
	    ./scripts/install-local-extension-product.sh "$$SCHEME" "$(INSTALL_DIR)" "$(LOCAL_DERIVED_DATA)"; \
	done

# Build + package one extension as a .tunaextension store artifact.
# Needs a Tuna binary for the declaration dump: /Applications/Tuna.app or TUNA_BINARY.
ext-package:
	$(require_target)
	@./scripts/tuna-extension package --scheme "$(TARGET)"

# Build + upload one extension to the store API.
ext-upload:
	$(require_target)
	@./scripts/tuna-extension upload --scheme "$(TARGET)"

# Test, build, publish, verify, tag, and push one extension.
release: test-extensions
	$(require_target)
	@./scripts/tuna-extension release --scheme "$(TARGET)"

# Prepare and preflight every extension before publishing any of them.
release-all: test-extensions
	@./scripts/release-all-extensions.sh $(EXTENSION_SCHEMES)

clean:
	rm -rf ./build
