ARCH := $(shell uname -m)
# One scheme per extension project. GitHubExtension's target kept its
# load-bearing TunaGitHub name; resolve-extension-scheme maps either spelling.
EXTENSION_SCHEMES := ArenaExtension BrewExtension ChromeExtension CleanShotExtension FancyTextExtension TunaGitHub GiphyExtension Messages2FAExtension MusicExtension MyMindExtension NotesExtension NotionExtension ObsidianExtension PoofExtension RemindersExtension SafariExtension SpotifyExtension ThingsExtension VikunjaExtension
DESTINATION := generic/platform=macOS
DEV_DESTINATION := platform=macOS,arch=$(ARCH)
DERIVED_DATA := ./build/dd
INSTALL_DIR := $(HOME)/Library/Application Support/Tuna/ExtensionsDev
LOCAL_DERIVED_DATA := ./build/dd-local
CONFIGURATION ?= Debug

.DEFAULT_GOAL := build-all
.PHONY: build-all test test-release-scripts test-local-tunakit-rewrite test-chromium-support test-extensions ext ext-all ext-local ext-all-local ext-package ext-upload release release-all clean

define require_target
	@test -n "$(TARGET)" || { echo "usage: make $@ TARGET=<Scheme>" >&2; exit 64; }
endef

define require_tuna_root
	@test -n "$(TUNA_ROOT)" || { echo "usage: make $@ TUNA_ROOT=/absolute/path/to/Tuna" >&2; exit 64; }
endef

# Compile every extension in Release.
build-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; ./scripts/tuna-extension build --scheme "$$SCHEME" --release >/dev/null; done; echo "All extensions build."

# Run release tooling regressions and every extension unit-test target.
test: test-release-scripts test-chromium-support test-extensions

test-release-scripts:
	@./tests/release-all-extensions-test.sh
	@./tests/cross-repo-paths-test.sh
	@./tests/run-xcodebuild-test.sh
	@./tests/local-tunakit-rewrite-test.sh
	@./tests/local-extension-tooling-test.sh

test-local-tunakit-rewrite:
	@./tests/local-tunakit-rewrite-test.sh

test-chromium-support:
	@swift test --package-path ChromiumExtensionSupport

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
		./scripts/run-xcodebuild test -project "$$PROJECT" -scheme "$$SCHEME" -configuration Debug -destination "$(DEV_DESTINATION)" -derivedDataPath "$(DERIVED_DATA)/tests/$$SCHEME" CODE_SIGNING_ALLOWED=NO; \
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

# Build selected extensions against Tuna's local TunaKit source and dev-install them. TARGET keeps
# the original single-target interface; TARGETS accepts a space-separated subset.
ext-local:
	$(require_tuna_root)
	@test -n "$(strip $(TARGET) $(TARGETS))" || { echo "usage: make $@ TARGET=<Scheme> or TARGETS='<Scheme> ...' TUNA_ROOT=/absolute/path/to/Tuna [CONFIGURATION=Release]" >&2; exit 64; }
	@./scripts/install-local-extensions.sh \
	  "$(TUNA_ROOT)" "$(INSTALL_DIR)" "$(LOCAL_DERIVED_DATA)" "$(CONFIGURATION)" \
	  $(strip $(TARGET) $(TARGETS))

# Build every extension against Tuna's local TunaKit source and dev-install it.
ext-all-local:
	$(require_tuna_root)
	@./scripts/install-local-extensions.sh \
	  "$(TUNA_ROOT)" "$(INSTALL_DIR)" "$(LOCAL_DERIVED_DATA)" "$(CONFIGURATION)" \
	  $(EXTENSION_SCHEMES)

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
