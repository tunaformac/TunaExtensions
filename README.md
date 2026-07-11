# TunaExtensions

First-party extensions for [Tuna](https://tunaformac.com), the macOS launcher.
This repo is the source of truth for every extension distributed through the
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
make ext-all          # build + install all into Tuna's ExtensionsDev for local development
./scripts/tuna-extension install --scheme ObsidianExtension
```

Open `TunaExtensions.xcworkspace` for Xcode work. After a dev install, restart Tuna to load changed
extension code.

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

Packaging derives store metadata from the built bundle's Swift declaration,
which requires a Tuna binary: `/Applications/Tuna.app` by default, or set
`TUNA_BINARY`. Until a Tuna release ships with `--dump-extension-declaration`,
point `TUNA_BINARY` at a dev build. Store screenshots live under `media/`.

Docs for the extension API live at https://tunaformac.com/docs.
