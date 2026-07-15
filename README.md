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
| BrewExtension | Search and manage Homebrew packages |
| CleanShotExtension | CleanShot X capture commands |
| GitHubExtension | Repos, issues, and pull requests |
| NotesExtension | Apple Notes search |
| NotionExtension | Notion pages and databases |
| ObsidianExtension | Obsidian vaults and notes |
| RemindersExtension | Apple Reminders |
| SafariExtension | Safari bookmarks, reading list, and tabs |
| ThingsExtension | Things to-dos and projects |

## Building

```bash
make                  # compile every extension (Release)
make test             # release-tooling checks plus every extension unit-test target
make test-tooling     # release-tooling checks only
make ext-all          # build + install all into Tuna's ExtensionsDev for local development
./scripts/tuna-extension install --scheme ObsidianExtension
```

Open `TunaExtensions.xcworkspace` for Xcode work. After a dev install, restart Tuna to load changed
extension code. The release-tooling tests require OpenSSL 3 (`brew install openssl@3`).

## TunaKit dependency

Projects pin TunaKit with an up-to-next-minor requirement because TunaKit is
in beta: breaking changes can land in minor releases and are called out in its
[changelog](https://github.com/tunaformac/TunaKit/blob/main/CHANGELOG.md).
Bump the pinned version deliberately, repo-wide, after reading the changelog.

## Packaging and releasing (maintainers)

```bash
./scripts/tuna-extension package --scheme ObsidianExtension
./scripts/tuna-extension release --scheme ObsidianExtension
```

After a release succeeds, verify the store item and the exact tag and commit printed by the command.
Then push that tag explicitly to the public repository (replace both example values with the printed
ones):

```bash
TAG="extensions/com.example.extension/v1.0"
RELEASE_COMMIT="0123456789abcdef0123456789abcdef01234567"
test "$(git rev-parse "$TAG^{commit}")" = "$RELEASE_COMMIT"
git push origin "refs/tags/$TAG:refs/tags/$TAG"
```

Do not use `git push --tags`; each verified extension release is pushed independently.

Packaging derives store metadata from the built bundle's Swift declaration,
which requires a Tuna binary. Local development falls back to `/Applications/Tuna.app`; releases
must set `TUNA_BINARY` to the Tuna executable from the exact extracted frozen signed/notarized
candidate. Store icons belong at
`media/icons/<id-or-slug>.<extension>` and screenshots at
`media/screenshots/<id-or-slug>/*`. Media supplied by this tooling must be tracked; curated server
media need not be duplicated here. `dist/store/` is generated output and is never used as a
listing-media source.

`make ext-package`, `make ext-upload`, `make ext-upload-all`, and `make ext-release` sign packages
with `op://Brainbow/Tuna/EXTENSIONS_STORE_SIGNING_PRIVATE_KEY` by default. Override that provider
with `EXTENSIONS_STORE_SIGNING_PRIVATE_KEY_OP`, or set `SIGNING_KEY` to a PEM file directly.
Packaging requires both `minTuna` and `minTunaKit` from the declaration or explicit `MIN_TUNA` and
`MIN_TUNAKIT` overrides; it never invents either floor. Store categories are curated separately and
are not copied from declarations.

Uploads require the selected extension, `.gitignore`, `Makefile`, `scripts/`, and `media/` to remain
clean before and after packaging, including staged and untracked files. A release also refuses an
existing version tag that does not point to the captured release commit; a matching tag makes
reruns safe. Before its first public request, `make ext-release` freezes the validated package and
metadata under `dist/release-state/<scheme>/<source-commit>/`. A retry at that exact commit reuses
those bytes instead of rebuilding a timestamped package. Preserve that state until the public item
and release tag are both verified and the exact tag is pushed; corrupt or mismatched state fails
closed. Never delete it after an uncertain upload response just to force a rebuild. If packaging was
killed before state was frozen, confirm that no release process is running before removing the empty
lock directory reported by the next attempt.

The uploader sends private snapshots of the frozen package and tracked listing media; media bytes
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
