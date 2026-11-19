# Extension Authoring Guide

This repository is the shared home for Tuna extensions. It contains the current implementations and
a reusable agent skill. Use the skill to protect the product design, then build alongside the real
extensions and submit the result here as a pull request.

## Give this to your coding agent

Copy [`skills/tuna-extension-authoring/SKILL.md`](../skills/tuna-extension-authoring/SKILL.md) into
your agent, paste its contents into the conversation, or install the directory in your agent's
skills folder. Then describe the product you want to integrate.

The skill deliberately requires the agent to inspect current examples and the integrated product,
present a complete design packet, and wait for your explicit approval before it creates files. That
approval gate is important: Tuna's nouns, verbs, targets, global scope, browse hierarchy, access,
and destructive actions should match your mental model before code makes them expensive to change.

## Prerequisites

- macOS 15 or later
- Xcode and the macOS SDK
- Tuna installed for manual loading
- `rg` (the repository scripts use ripgrep)
- Network access for the released [TunaKit](https://github.com/tunaformac/TunaKit) package

TunaKit is public beta. This repository currently pins `1.22.x`; always confirm the current pin in
the extension projects and read the TunaKit changelog before raising it. Claim only compatibility
floors you test.

## Start an extension

After the design packet is approved, clone this repository and create a branch:

```bash
git clone https://github.com/tunaformac/TunaExtensions.git
cd TunaExtensions
git switch -c add-example-extension
```

When this repository is checked out beside Tuna, remember that a linked Tuna worktree is nested
under the primary checkout rather than beside this repository. Resolve the sibling checkout from
Tuna's common Git directory instead of using `../TunaExtensions` from the worktree:

```bash
TUNA_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
EXTENSIONS_ROOT="$(dirname "$TUNA_ROOT")/TunaExtensions"
```

Copy the closest existing extension project, rename its product, scheme, source folder, declaration,
and bundle identifier, then remove behavior that is not part of the approved design. Keep the new
extension as a top-level `<Name>Extension` directory and add its project to
`TunaExtensions.xcworkspace`. Pin TunaKit consistently with the other projects and use the shared
repository scripts for building, testing, installation, and packaging.

Local TunaKit builds copy an extension before changing it, leaving its checked-in project and
`Package.resolved` untouched. The copy must contain exactly one standard TunaKit remote package
reference and one TunaKit pin in a `Package.resolved` version 1, 2, or 3 file. The rewrite preserves
the pin's semantic version while pointing its temporary URL and revision at the local package;
unexpected or ambiguous forms fail before Xcode runs.

Do not preserve copied catalog, provider, connection, or navigation machinery merely because it was
present in the example. The approved design determines the implementation; the example only supplies
known-good project wiring and a relevant API recipe.

Chromium-based browser extensions are separate products but may reference the repository's
Foundation-only `ChromiumExtensionSupport` package for verified profile, bookmark, and launch
contracts. Keep browser-specific declarations, catalogs, actions, branding, and capabilities in
the owning extension; do not use that package as a browser-neutral abstraction for Safari or Firefox.

## Current shape and recipe index

Refresh this list against every `*Extension.swift` before designing; names in catalog IDs do not
determine presentation or search behavior.

| Shape | Examples | Start here when |
| --- | --- | --- |
| Action-only text transform | `FancyTextExtension` | Tuna already supplies the subject and the extension only contributes a verb and results. |
| Static destinations and commands | `ThingsExtension`, `SafariExtension/SafariMetaCatalog.swift`, `CleanShotExtension` | The domain exposes fixed destinations, URL-scheme utilities, or directly runnable commands rather than a content corpus. |
| App companion commands with deferred children | `CleanShotExtension` | An app is the natural entry point and expensive children should load only on browse. |
| App-enriched deferred local data | `Messages2FAExtension` | Private or fast-changing local data should load only when browsed and refresh from native change signals. |
| Direct indexed local content | `NotesExtension`, `RemindersExtension` | A bounded local corpus belongs directly in global search. |
| Indexed content plus opt-in browse root | `SafariExtension`, `PoofExtension`, `ObsidianExtension`, parts of `RemindersExtension` | Everything should be browsable while users choose which concrete items enter global search. |
| Hierarchical local files/config | `ObsidianExtension`, `PoofExtension` | External folders, files, or native config form the domain hierarchy and writes must preserve native data. |
| Dynamic local CLI | `BrewExtension` | Enumeration and mutations are command-driven; expensive work and completion need explicit ownership. |
| Remote deferred browse/write | `ArenaExtension` | Network content is browsed lazily without type-to-search, with connection-scoped writes and partial failures. |
| Remote browse and scoped search | `GitHubExtension`, `NotionExtension` | Provider search runs as users type inside explicit roots, with connections and deferred state. |
| Remote paged search/grid | `MyMindExtension` | Large visual libraries need paging, thumbnails, resolution, and Quick Look. |
| Scripted app library plus remote search | `MusicExtension` | An app's data is only reachable through Apple Events, a helper playlist or similar stands in for missing scripting objects, and a framework adds remote search and enrichment. |
| Framework-backed live data | `RemindersExtension` | A system framework owns authorization, querying, writes, and change notifications. |

Useful implementation landmarks:

- Paired content/root declarations: `SafariExtension/SafariExtension.swift`,
  `PoofExtension/PoofExtension.swift`, `ObsidianExtension/ObsidianExtension.swift`
- Eager, deferred, and scoped roots: `ArenaExtension/ArenaCatalog.swift`,
  `CleanShotExtension/CleanShotCommandsCatalog.swift`, `NotionExtension/NotionCatalog.swift`
- Item-level hierarchy and native files: `ObsidianExtension/ObsidianItems.swift`
- Provider boundaries: `BrewExtension/BrewCLI.swift`, `MusicExtension/MusicAppleScript.swift`, `Messages2FAExtension/MessagesDatabase.swift`,
  `NotesExtension/NotesDatabase.swift`, `PoofExtension/PoofConfig.swift`,
  `RemindersExtension/RemindersAuthorization.swift`
- Connections and credentials: `ArenaExtension/ArenaExtension.swift`,
  `GitHubExtension/GitHubCatalogSupport.swift`, `NotionExtension/NotionCatalogSupport.swift`,
  `MyMindExtension/MyMindExtension.swift`
- Action grammar and results: `FancyTextExtension/FancyTextActionsCatalog.swift`,
  `ArenaExtension/ArenaActionsCatalog.swift`, `PoofExtension/PoofActionsCatalog.swift`,
  `RemindersExtension/RemindersActionsCatalog.swift`
- Direct commands and execution-time subjects: `CleanShotExtension/CleanShotCommandsCatalog.swift`,
  `SafariExtension/SafariMetaCatalog.swift`
- Focused tests: `CleanShotExtension/CleanShotExtensionTests.swift`,
  `Messages2FAExtension/Messages2FAExtensionTests.swift`, `MusicExtension/MusicExtensionTests.swift`,
  `MyMindExtension/MyMindExtensionTests.swift`,
  `ObsidianExtension/ObsidianExtensionTests.swift`, `PoofExtension/PoofExtensionTests.swift`,
  `RemindersExtension/RemindersExtensionTests.swift`

## Development commands

Run the shared tooling from the repository root:

```bash
./scripts/tuna-extension build --scheme ExampleExtension
./scripts/tuna-extension build --scheme ExampleExtension --release
./scripts/tuna-extension install --scheme ExampleExtension --restart
./scripts/tuna-extension logs --last 20m       # inspect extension loading
make test                                      # run repository checks and extension tests
```

For coordinated work against an unreleased TunaKit checkout, use the local install path. Exact
schemes and short names are accepted, and a selected subset shares one TunaKit preparation:

```bash
make ext-local TARGETS="MyMind Safari" TUNA_ROOT=/absolute/path/to/Tuna
make ext-local TARGET=MyMind TUNA_ROOT=/absolute/path/to/Tuna CONFIGURATION=Release
```

Local Release builds intentionally use only the host architecture, matching the generated TunaKit
framework. Published release/package commands remain universal and use released TunaKit.

The shared build and test commands route Xcode through `scripts/run-xcodebuild`. Complete output is
retained in `build/xcodebuild`; builds and tests use `xcsift` when available and report the first
compiler errors plus the log path on failure. Use `make test-release-scripts` when changing only
repository tooling, and `make test-extensions` when validating extension test targets.

Before opening a pull request, build and test the extension, document setup and privacy behavior,
and add focused tests. Add a `STORE.md` with the store description, category, and the permissions
the extension asks for (plus `requires_app: true` if it does nothing without its app), and keep
`CHANGELOG.md` current; the
[README](../README.md#store-listing-copy) describes both. Maintainers use the repository release tooling for packaging and publication;
contributors should not upload extension packages directly.

## Validation checklist

Automated checks should cover declaration IDs and references, item identity/type/search fields,
catalog shape and empty/error states, action subject/target grammar, provider parsing, and bundle IDs.
For manual validation, inspect Settings → Extensions and Sources, global scope defaults, direct and
app-enriched browse, action and target panes, write confirmation, live refresh, previews, Quick Look,
and logs. Restart Tuna after binary changes; a rescan only reloads catalog data.

The canonical API reference and distribution guide live at
<https://tunaformac.com/docs/extension-development>. The implementations in this repository remain
the best evidence for conventions at the currently pinned TunaKit version.
