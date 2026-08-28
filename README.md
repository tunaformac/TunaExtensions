# TunaExtensions

First-party extensions for [Tuna](https://tunaformac.com), the macOS launcher.
This repo is the source of truth for every first-party extension distributed through the
Tuna store — and a set of real, working examples for building your own.

Each extension is a folder with its own Xcode project, flat sources, and an
`Extension` subclass that declares its catalogs in Swift. They all depend on
[TunaKit](https://github.com/tunaformac/TunaKit) as a binary Swift package —
exactly the setup a third-party extension uses.

| Extension | What it does |
| --- | --- |
| ArenaExtension | Browse Are.na channels and save links or text |
| BrewExtension | Search and manage Homebrew packages |
| CleanShotExtension | Browse recent CleanShot images and run capture commands |
| FancyTextExtension | Turn text into searchable Unicode styles |
| GitHubExtension | Repos, issues, and pull requests |
| MyMindExtension | Search, browse, resolve, and save mymind objects |
| NotesExtension | Apple Notes search |
| NotionExtension | Notion pages and databases |
| ObsidianExtension | Browse Obsidian vaults, folders, and notes |
| PoofExtension | Find, paste, and manage Poof text snippets |
| RemindersExtension | Search reminders and create them in specific lists |
| SafariExtension | Safari bookmarks, reading list, and tabs |
| ThingsExtension | Things to-dos and projects |

## Building

```bash
make                  # compile every extension (Release)
make test             # run every extension unit-test target
make ext-all          # build + install all into Tuna's ExtensionsDev for local development
make ext-all-local    # build + install all against ../Tuna's current local TunaKit
make ext-local TARGET=SafariExtension TUNA_ROOT=../Tuna
./scripts/tuna-extension install --scheme ObsidianExtension
```

Open `TunaExtensions.xcworkspace` for Xcode work. After a dev install, restart Tuna to load changed
extension code. `ext-local` and `ext-all-local` create an ignored, temporary binary package from
the selected Tuna checkout without changing the projects or their checked-in package resolutions.
The release-backed `ext`, build, test, package, upload, and release commands continue to use the
published TunaKit package.

## TunaKit dependency

Projects pin TunaKit with an up-to-next-minor requirement because TunaKit is
in beta: breaking changes can land in minor releases and are called out in its
[changelog](https://github.com/tunaformac/TunaKit/blob/main/CHANGELOG.md).
Bump the pinned version deliberately, repo-wide, after reading the changelog.

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
which requires a Tuna binary. It uses `TUNA_BINARY` when provided, then looks for the sibling debug
build at `../Tuna/build/dd/Build/Products/Debug/Tuna.app/Contents/MacOS/Tuna`, then falls back to
`/Applications/Tuna.app` and `~/Applications/Tuna.app`. A store icon belongs beside its sources at
`<Extension>/icon.png` — every extension here has one. `media/icons/<id-or-slug>.<extension>` still
works for icons curated outside an extension directory. Screenshots live at
`media/screenshots/<id-or-slug>/*`. Media supplied by this tooling must be tracked; curated server
media need not be duplicated here. `dist/store/` is generated output and is never used as a
listing-media source.

`make ext-package`, `make ext-upload`, `make release`, and `make release-all` sign packages
with `op://Brainbow/Tuna/EXTENSIONS_STORE_SIGNING_PRIVATE_KEY` by default. Override that provider
with `EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP`, or set `SIGNING_KEY` to a PEM file directly.
Packaging requires both `minTuna` and `minTunaKit` from the declaration or explicit `MIN_TUNA` and
`MIN_TUNAKIT` overrides; it never invents either floor. Store categories are curated separately and
are not copied from declarations.

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
fails closed. After any upload, the response and a fresh public readback must match, and the public
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
