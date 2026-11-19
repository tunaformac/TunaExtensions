# TunaExtensions

First-party extensions for [Tuna](https://tunaformac.com), the macOS launcher.
This repo is the source of truth for every first-party extension distributed through the
Tuna store — and a set of real, working examples for building your own.

Each extension is a folder with its own Xcode project, flat sources, and an
`Extension` subclass that declares its catalogs in Swift. They all depend on
[TunaKit](https://github.com/tunaformac/TunaKit) as a binary Swift package —
exactly the setup a third-party extension uses.

## Contribute an extension

Give your coding agent the pasteable
[`tuna-extension-authoring` skill](skills/tuna-extension-authoring/SKILL.md). It makes the agent
inventory current examples, inspect the product being integrated, present a full design packet, and
wait for your explicit approval before implementing anything.

Extensions are developed together in this repository so they can follow current examples and ship
through the same review and release process. Clone the repository, create your extension on a branch,
and open a pull request when it is ready:

```bash
git clone https://github.com/tunaformac/TunaExtensions.git
cd TunaExtensions
git switch -c add-example-extension
```

Read the [extension authoring guide](docs/extension-authoring.md) for prerequisites, current extension
shapes, recipe files, project conventions, and validation. Start from the closest real extension
below rather than a generic template, and include the new project in `TunaExtensions.xcworkspace`.

## Extensions

| Extension | What it does |
| --- | --- |
| ArenaExtension | Browse Are.na channels and save links or text |
| BrewExtension | Search and manage Homebrew packages |
| ChromeExtension | Browse Chrome bookmarks and launch profiles |
| CleanShotExtension | Browse recent CleanShot images and run capture commands |
| CloudShareExtension | Upload files to S3 storage and copy the public link |
| FancyTextExtension | Turn text into searchable Unicode styles |
| GitHubExtension | Repos, issues, and pull requests |
| GiphyExtension | Search, preview, and paste GIFs from GIPHY |
| Messages2FAExtension | Find recent authentication codes from Apple Messages |
| MusicExtension | Control Music, browse your library, and search Apple Music |
| MyMindExtension | Search, browse, resolve, and save mymind objects |
| NotesExtension | Apple Notes search |
| NotionExtension | Notion pages and databases |
| ObsidianExtension | Browse Obsidian vaults, folders, and notes |
| PoofExtension | Find, paste, and manage Poof text snippets |
| RemindersExtension | Search reminders and create them in specific lists |
| SafariExtension | Safari bookmarks, reading list, tabs, and Last Download (Resolve by default, with file actions available) |
| SpotifyExtension | Control Spotify, browse your library, and search Spotify |
| StrongboxExtension | Copy Strongbox passwords, usernames, and one-time codes through its local MCP interface |
| ThingsExtension | Things to-dos and projects |

## Building

```bash
make                  # compile every extension (Release)
make test             # run every extension unit-test target
make ext-all          # build + install all into Tuna's ExtensionsDev for local development
make ext-all-local TUNA_ROOT=/absolute/path/to/Tuna
make ext-local TARGET=Safari TUNA_ROOT=/absolute/path/to/Tuna
make ext-local TARGETS="MyMind Safari" TUNA_ROOT=/absolute/path/to/Tuna
make ext-local TARGET=MyMind TUNA_ROOT=/absolute/path/to/Tuna CONFIGURATION=Release
./scripts/tuna-extension install --scheme ObsidianExtension
```

Open `TunaExtensions.xcworkspace` for Xcode work. After a dev install, restart Tuna to load changed
extension code. `ext-local` and `ext-all-local` create an ignored, temporary binary package from
the selected Tuna checkout without changing the projects or their checked-in package resolutions.
Chromium-based browser extensions share their storage and launch primitives through the local,
Foundation-only `ChromiumExtensionSupport` package while remaining separate store extensions.
Targets accept exact schemes or short extension names; `GitHub` and `GitHubExtension` retain the
load-bearing `TunaGitHub` scheme. `TARGETS` validates the full subset before preparing TunaKit once.
Local Debug and Release builds use the host architecture to match the generated framework.

The temporary dependency rewrite accepts `Package.resolved` formats 1–3, preserves each project's
resolved TunaKit version when pins differ, and requires exactly one recognized TunaKit project
reference and resolved pin. Unexpected or ambiguous forms fail before Xcode runs.
The release-backed `ext`, build, test, package, upload, and release commands continue to use the
published TunaKit package.

Shared commands retain complete Xcode output under `build/xcodebuild` while keeping terminal output
concise. If `xcsift` is installed it formats live build/test diagnostics; failures also print the
first compiler errors and retained log path. Run `make test-release-scripts` for tooling-only
changes, `make test-extensions` for extension tests, or `make test` for both.

## TunaKit dependency

Projects pin TunaKit with an up-to-next-minor requirement because TunaKit is
in beta: breaking changes can land in minor releases and are called out in its
[changelog](https://github.com/tunaformac/TunaKit/blob/main/CHANGELOG.md).
Bump the pinned version deliberately, repo-wide, after reading the changelog.
An extension may require a newer TunaKit than the rest when it needs new API, so each scheme
builds into its own derived data folder (`build/dd/<Scheme>`; set `TUNA_EXTENSION_DERIVED_DATA`
to move the parent folder).

## Packaging and releasing (maintainers)

```bash
make release TARGET=ObsidianExtension
make release-all
```

The command tests, builds, signs, uploads, downloads and verifies the public package, then creates
and pushes its annotated tag. Before `release-all` publishes anything, it builds and packages every
extension, preflights every candidate against the store, and verifies the complete release input
set is still clean. It then verifies already-published matching versions and only uploads versions
that are newer or need their bytes repaired.

Packaging derives store metadata from the built bundle's Swift declaration,
which requires a Tuna binary. It uses `TUNA_BINARY` when provided, then the debug build under an
explicit `TUNA_ROOT`, then falls back to `/Applications/Tuna.app` and `~/Applications/Tuna.app`.
When coordinating changes from a Tuna worktree, prefer Tuna's
`scripts/tuna-extensions.sh <target>` wrapper; it passes both paths explicitly. A store icon belongs beside its sources at
`<Extension>/icon.png`, a 1024×1024 PNG. For an SF Symbol on a flat tile (Cloud Share, Strongbox),
`swift scripts/render-symbol-icon.swift <symbol> <hex> <weight> <glyph-height> <out.png>` renders one in
the same style. `media/icons/<id-or-slug>.<extension>` still
works for icons curated outside an extension directory. Screenshots live at
`media/screenshots/<id-or-slug>/*`. Media supplied by this tooling must be tracked; curated server
media need not be duplicated here. `dist/store/` is generated output and is never used as a
listing-media source.

`make ext-package`, `make ext-upload`, `make release`, and `make release-all` sign packages
with `op://Brainbow/Tuna/EXTENSIONS_STORE_SIGNING_PRIVATE_KEY` by default. Override that provider
with `EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP`, or set `SIGNING_KEY` to a PEM file directly.
Packaging requires both `minTuna` and `minTunaKit` from the declaration or explicit `MIN_TUNA` and
`MIN_TUNAKIT` overrides; it never invents either floor.

Packaging also refuses a floor the build can't run on. Every TunaKit symbol the built binary
imports must exist in the minimum TunaKit release, whose published xcframework is downloaded once,
checked against the checksum in TunaKit's `Package.swift` at that tag, and reduced to a list of
exported symbols cached in `build/tunakit-floor/` (a warm cache needs no network). A failure names
the missing symbols and the first TunaKit and Tuna releases that have them. The minimum Tuna must
also ship at least the minimum TunaKit, per `scripts/tuna-tunakit-versions.tsv`; add a row there
when a Tuna release bumps TunaKit. Run the check alone with
`scripts/check-tunakit-floor.py --bundle <built bundle> --min-tuna 0.96 --min-tunakit 1.22.0`.

### Store listing copy

The store listing is built from files beside each extension's sources:

- The **summary** is the first line of the declaration's `description`.
- **What it adds** (catalog names, action titles, setting and connection kinds) and the apps it
  **works with** come from the built declaration via `Tuna --dump-extension-declaration`.
- **Release notes** are the extension's `CHANGELOG.md` section headed with the packaged version
  (`## 0.13`). A new version without one ships its `## Unreleased` section instead; a version
  already in the store only ever takes its own section, so refreshing its listing never replaces
  its notes with unreleased changes.
- The **description**, categories, permissions, and links come from an optional `STORE.md`:

```markdown
---
categories: [media]
warnings: [automation]
support_url: https://github.com/tunaformac/TunaExtensions/tree/main/CleanShotExtension
requires_app: true
---
Run CleanShot X captures from Tuna and act on recent screenshots…
```

The frontmatter accepts `categories`, `tags`, `warnings` (inline lists) and `developer_url`,
`support_url`, `privacy_url` (http(s) URLs), and `requires_app` (`true` or `false`); anything else
fails packaging. Set `requires_app: true` only when the extension does nothing useful without the
app it works with installed. The store then warns people who don't have that app; otherwise it
says the extension works best with it. Leaving it out means `false`. Categories must be one
of `browsers`, `developer`, `files`, `media`, `notes`, `productivity`, `security`, `tasks`, `text`,
or `web`. Warnings are the permissions users are asked for, from the store's codes: `automation`,
`accessibility`, `full_disk_access`, `screen_recording`, `microphone`, `camera`, `contacts`,
`calendar`, `reminders`, `photos`, `location`, `network`. The body is the listing's Markdown
description, written for people using Tuna rather than building it. With a `STORE.md`, its fields
are the listing: removing the description, a link, or every category or warning clears it in the
store. Without one, values curated in the store admin are left alone. Text is trimmed and blank
text counts as empty, as the store normalizes it.

Listing copy is not part of the package. When the store already has the same version and bytes but
its listing differs, `make ext-upload` and `make release` refresh the listing without re-uploading
the package, and editing `STORE.md`, `CHANGELOG.md`, or `README.md` does not count as a source
change for release-tag reuse. To backfill listings, commit the copy and run `make release-all`.

Uploads require the selected extension, `.gitignore`, `Makefile`, `scripts/`, and `media/` to remain
clean before and after packaging, including staged and untracked files. `release-all` applies that
check across every extension and every tracked `Package.resolved`, after preparing all packages and
again after all store preflights. A release also refuses an existing version tag that does not point
to the captured release commit; a matching tag makes reruns safe. Packages use fixed timestamps and
sorted ZIP entries, so rerunning from the same source produces the same bytes. Releases made before
deterministic packaging are compared by their signed manifest and payload contents when their outer
ZIP bytes differ; compiler-dependent packages may also reuse their immutable public bytes when the
extension source still matches its annotated tag.

The uploader sends private snapshots of the package and tracked listing media; media bytes
come from the captured release commit rather than mutable worktree paths, and ignored `dist/store/`
output is never uploaded directly.

Before uploading, the release command reads the public store item without authentication. An exact
same-version release is accepted only when uploader-controlled metadata, expected listing media,
and the public artifact's downloaded size and SHA-256 all match. Missing media, a missing artifact,
or mismatched public bytes triggers a same-version recovery upload; controlled metadata drift still
fails closed, while drift in listing copy (description, release notes, categories, warnings, links,
contents) triggers a package-free listing refresh. After any upload, the response and a fresh public readback must match, and the public
artifact is downloaded and verified again before a release tag can be created. Upload credentials
are resolved only when a PUT is needed and are passed through a private curl configuration file;
public metadata and artifact requests never receive the bearer header.

For a non-interactive build with a contributor's Apple Development identity, pass both the team and
the identity SHA-1 shown by `security find-identity -v -p codesigning`:

```bash
TUNA_DEVELOPMENT_TEAM=YOURTEAMID \
TUNA_CODE_SIGN_IDENTITY=IDENTITY_SHA1 \
  ./scripts/tuna-extension build --scheme ObsidianExtension --release
```

Docs for the extension API live at https://tunaformac.com/docs.

## License

TunaExtensions is available under the [MIT License](LICENSE).
