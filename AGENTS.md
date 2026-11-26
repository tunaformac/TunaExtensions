# TunaExtensions Agent Guide

Keep changes small and readable, and keep the closest user/developer documentation in sync.

## Checkout roots

Never infer one checkout from the current directory or a relative `../Tuna` path. Resolve the
checkout you are working in and pass cross-repository roots explicitly:

```sh
EXTENSIONS_ROOT="$(git rev-parse --show-toplevel)"
TUNA_ROOT="$(git -C /path/to/Tuna rev-parse --show-toplevel)"
```

When starting from a Tuna checkout or linked worktree, prefer its wrapper:

```sh
"$TUNA_ROOT/scripts/tuna-extensions.sh" ext-local TARGET=MyMindExtension
```

It resolves TunaExtensions from Tuna's primary checkout (or `TUNA_EXTENSIONS_ROOT`), then passes
the exact `TUNA_ROOT` and `TUNA_BINARY`. Otherwise use an explicit working directory, for example
`make -C "$EXTENSIONS_ROOT" test-release-scripts` or `cd "$EXTENSIONS_ROOT"`; do not rely on the
caller's current directory.

## Tooling gates

- Policy lint (rules P1–P14; `scripts/lint-extensions --help`): `make -C "$EXTENSIONS_ROOT" lint-extensions`
- Release/path tooling only: `make -C "$EXTENSIONS_ROOT" test-release-scripts`
- All extension unit tests: `make -C "$EXTENSIONS_ROOT" test-extensions`
- Full test gate: `make -C "$EXTENSIONS_ROOT" test`
- Release build of every extension: `make -C "$EXTENSIONS_ROOT"`
- Reviewing a contributed pull request: `skills/review-extension-pr/SKILL.md`; open PRs and their
  review state: `"$EXTENSIONS_ROOT/scripts/review-queue"`

Use `./scripts/tuna-extension build|install --scheme <Scheme>` for one extension. Xcode commands
belong behind `scripts/run-xcodebuild`; it retains complete logs under `build/xcodebuild`, uses
`xcsift` for builds and tests when installed, and prints concise failure diagnostics.
