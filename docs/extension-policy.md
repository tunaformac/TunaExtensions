# Extension Contribution Policy

Tuna extensions are native code. Tuna loads each one into its own process, where it runs with
Tuna's permissions: Keychain, Accessibility, Automation and the network. Tuna can't sandbox an
extension, and every store release is signed with Brainbow's store key. A bug or a careless change
in one extension is therefore a bug in Tuna, shipped under the maintainer's signature.

This policy keeps that safe without making the maintainer read every line of every update. It is
written for contributors and for their coding agents. The rule IDs (P1–P14) are stable: the
[authoring skill](../skills/tuna-extension-authoring/SKILL.md), the pull request template,
`make lint-extensions` and reviews all cite them.

## How review works

1. **Admission (once per extension).** The pull request that adds an extension gets a full
   review: design, provider access, credentials, permissions, and every rule below. Admission is
   where identity, scope and the risk surface are agreed.
2. **Updates (routine).** After admission, an update can ship without detailed review when it:
   - changes only files inside the extension's own folder and its own store media
     (`media/screenshots/<slug>/`, `media/icons/<slug>.*`),
   - passes CI, and
   - touches nothing on the [risk list](#risk-list).
3. **Escalation.** An update that touches anything on the risk list always goes to the maintainer,
   however small it is. Say so in the pull request rather than leaving it to be found.

Each open pull request has a standing review agent that follows the
[review skill](../skills/review-extension-pr/SKILL.md). It classifies the pull request,
runs the gates, checks every rule and reproduces what it finds. It approves fork CI runs whose
diff leaves shared tooling alone, and posts its review as a PR comment starting with "(Agent) "
on its own when the policy answers everything. It never approves or merges a pull request: the
maintainer merges. It brings the maintainer only the questions this policy doesn't answer, and
every risk-list item, holding that review as a draft until they answer. `scripts/review-queue`
lists open pull requests with their kind (admission, update or tooling), whether they need a
review or are waiting on the contributor, their CI state, and the paths that put them on the risk
list.

[`.github/CODEOWNERS`](../.github/CODEOWNERS) gives the maintainer everything and makes each
contributed extension's original author a co-owner of its folder and its own store media, so either
of them can approve an update confined to them. The pull request that admits an extension adds its
author's lines there.

`scripts/extension-risk BASE HEAD` is the automation that flags risky diffs. It reports each
touched extension as an admission or an update, every risk-list hit with the diff lines behind it
(new hosts and URL origins, Apple Events targets, URL schemes, Keychain, connection and secret
use, permission APIs and plist keys, destructive actions, paths into other apps' storage, process
launches, build scripts and new dependencies), and every changed path outside the extensions and
their own media as `ci` (something CI executes) or `shared`, the same flags `scripts/review-queue`
shows. An admission's own registration (its Makefile scheme, workspace entry and README row) is
`reg`: expected, and not a risk. Its content rules are best effort and err towards flagging: a flag means "look
here", not "rejected".

After a merge to main, the release workflow publishes an update on its own when CI (tests and
`make lint-extensions`) has passed on that commit, the extension is already in the store and has
an XCTest target, its version is newer than the store's, and nothing since its last release tag
needed the maintainer: `extension-risk` finds no hit from that tag to main, no merged change
touched the extension together with anything outside it, and the push changed no shared files.
Everything else (admissions, risk-list hits, shared changes, extensions without tests) is listed in the workflow summary as needing a manual release, which the
maintainer reviews and runs with `make release`. A merged risky change keeps an extension on the
manual path until the maintainer has released it, however small the updates after it.

A pull request waiting on its contributor gets a friendly nudge after 30 days without activity
and is closed after 60, with a note that it can be reopened any time.

Every pull request, admission or update, carries the self-review checklist from the
[pull request template](../.github/pull_request_template.md): each rule ticked, or marked "n/a
because…". The authoring skill makes the contributor's agent run it.

## Rules

Where a rule can be checked mechanically, `make lint-extensions` checks it and names the rule ID.
The rest are checked by the contributor's self-review and, at admission, by the maintainer. An
extension that predates a rule should meet it in the code an update touches.

### P1 Identity

The bundle ID is `com.brnbw.tuna.plugins.<name>`, the folder is `<Name>Extension`, and the scheme is
named like the folder. The extension is registered in `TunaExtensions.xcworkspace`, in
`EXTENSION_SCHEMES` in the `Makefile`, and in the README's extension table. Credit the author in the
declaration's `metadata.author`, not in the bundle ID.

*Why:* the bundle ID becomes the permanent store identity and the Keychain and defaults namespace;
it can't change after the first release.

### P2 Licence and privacy

The repository [LICENSE](../LICENSE) covers every extension: no per-extension `LICENSE` or
`PRIVACY.md`. Privacy notes live in the extension README's "Privacy" section and in `STORE.md`.

*Why:* one licence and in-repo privacy notes can't drift away from the code they describe.

### P3 Global search defaults

Catalogs whose items have side effects when run (they write, send, delete, control another app or
run third-party code, such as plugin commands) declare `initialGlobalScope: .none`. Read-only
catalogs may use `.all`, including commands that only produce a result in Tuna (Translate's
"Translate to German" returns text and changes nothing).

*Why:* a command in global search can fire by accident from an unrelated query; users opt in.

### P4 Launch cost

Tuna scans every enabled source at launch, whether or not it is in global search. A scan does no
heavy network or disk work (no bulk downloads, no thumbnail prefetch); fetch lazily on first browse,
for example from a browse root's `loadChildren`. Scans are bounded and time out.

*Why:* every enabled extension adds to Tuna's launch, for every user, whether they use it or not.

### P5 Storage and logging

Regenerable caches go in TunaKit's `RuntimeEnvironment.cachesDirectory()`, not Application
Support, inside a folder named after the extension's bundle ID (both directories are shared by
every extension). Secrets are stored only through Tuna connections or the Keychain. Never log secrets or user
content; use private log formatting. Tests don't write to the real user defaults or
`~/Library/Preferences` (remove any test suite domain in teardown).

*Why:* caches shouldn't be backed up or grow forever, and logs and test leftovers outlive the
moment they were written.

### P6 Network

HTTPS only, except literal loopback addresses and `localhost`. Credentials go only to the
configured origin: refuse cross-origin and HTTPS-to-HTTP redirects, and test that the refusal is
actually wired into the request path, not just the delegate in isolation. Every request has a
timeout. With TunaKit 1.24 or later, use `CredentialedHTTPClient` (see "Calling an authenticated
HTTP API" in Tuna's extension docs): it enforces all of this. Hand-rolled clients remain
acceptable for extensions on older TunaKit floors, but must meet the same rule and test it.

*Why:* a default `URLSession` replays a request body, password included, to wherever a redirect
points.

### P7 Command queue

Tuna runs accepted commands one at a time. Long work (pairing, OAuth, uploads, deploys) returns a
background task (`CommandBackgroundTask`, as in `SpotifyExtension/SpotifyAuth.swift` and
`BrewExtension/BrewActionsCatalog.swift`), honours cancellation, and never shows modal UI while
holding the queue.

*Why:* while one command waits on a dialog, every other command, hotkey and Combo leaf waits
behind it.

### P8 Interaction

Enter on an app item opens the app: don't use `preferredActions` to put a target-requiring action
first on app items. Destructive actions go through Tuna's confirmation. An action is offered
whenever it applies to fresh state; don't hide actions based on state cached at scan time (offer
both **Turn On** and **Turn Off**, and let the provider's answer decide).

*Why:* Tuna has no periodic rescan, so scan-time state is often launch-time state, and Enter on an
app is muscle memory.

### P9 IDs

Item and catalog IDs are stable and unique. With multiple accounts or connections, qualify them by
the connection record ID, never by a mutable name or URL.

*Why:* ranking history, abbreviations, settings and command history are keyed by ID; an ID that
changes loses them.

### P10 Honesty

Incomplete results (pagination caps, partial per-connection failures, capped counts) are visible to
the user, and so is an empty state with a reason ("Open the app to load your notes" rather than an
empty success). README, `STORE.md` and privacy claims match the code: say when content becomes a
public URL, and don't promise live refresh the code doesn't do.

*Why:* a silent gap looks like missing data, and listing copy is a promise made under Tuna's name.

### P11 Tests

Every extension has an XCTest target in its scheme. Tests are offline: no network and no real
credentials; live tests are opt-in through an environment variable. Minimum coverage:

- declaration: every catalog, action and type ID is unique and resolves;
- parsing, from fixtures captured from the real provider;
- URL and request building, including hostile input;
- action applicability: which subjects and targets each action accepts and rejects.

Tests that need an installed app should use a synthetic bundle in a temporary folder so they run
everywhere, including CI.

*Why:* updates ship on CI alone, so the tests are what stands between a change and users.

### P12 Release hygiene

- A new extension debuts with a single `CHANGELOG.md` section for the version it ships.
- Screenshots sit flat in `media/screenshots/<slug>/` (the uploader ignores subfolders), one
  appearance, a handful of shots. `<slug>` is the folder name without `Extension`, lowercased
  and hyphenated (`HueExtension` → `hue`, `OpenTerminalHereExtension` → `open-terminal-here`);
  use the same slug for `media/icons/<slug>.*`.
- `STORE.md` links (`developer_url`, `support_url`, `privacy_url`) and README media point at the
  tunaformac repository or tunaformac.com, not a personal repository.
- `icon.png` is 1024×1024.
- `minTuna` and `minTunaKit` pass the TunaKit floor check.
- The minimum macOS comes from the deployment target (`LSMinimumSystemVersion =
  $(MACOSX_DEPLOYMENT_TARGET)`), set on both the framework and test targets.

*Why:* release notes, screenshots and links are taken from these files exactly as they are, and
compatibility floors are enforced from them.

### P13 Scope

First releases are small and truthful. Avoid reading another app's private or undocumented
storage, or make it explicitly best-effort with a visible degraded state. Leave out test hooks,
migrations from out-of-tree predecessors, and AppKit workarounds that the first release doesn't
need.

*Why:* every line becomes the maintainer's to sign and keep working; private formats break without
notice.

### P14 Shared tooling

Changes outside the extension's folder (scripts, CI, shared docs, other extensions) are separate
pull requests, or explicitly called out in the one that needs them. Shared scripts never
special-case one extension; fix the extension's data to fit the script instead (for example, name
the screenshots folder so the existing lookup finds it).

*Why:* shared changes affect every extension and every release, so they need their own review.

## Risk list

These changes always need the maintainer, even in an update to an admitted extension:

- a new network host, or credentials sent somewhere new;
- a new app scripted through Apple Events, or a new URL scheme invoked with user data;
- new Keychain, secret or connection use, or a new permission (EventKit, Contacts,
  Accessibility…);
- a new destructive action;
- any change outside the extension's own folder and its own store media (this includes other
  extensions' media, the workspace, the `Makefile` and the README table);
- reading another app's private storage.

Name every item that applies in the pull request. When unsure, list it.
