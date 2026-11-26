## What and why

<!-- What changes for people using Tuna, and why. Admission of a new extension, or an update? -->

## Policy checklist

<!-- One line per rule from docs/extension-policy.md. Tick it, or write "n/a because …". -->

- [ ] P1 Identity: bundle ID, folder, scheme, workspace, Makefile, README table
- [ ] P2 Licence & privacy: no per-extension LICENSE/PRIVACY.md; Privacy in README and STORE.md
- [ ] P3 Global search: command/side-effect catalogs start at `.none`
- [ ] P4 Launch cost: scans are light, bounded and time out; heavy work waits for browse
- [ ] P5 Storage & logging: caches in `cachesDirectory()`, secrets in Keychain/connections, no secrets or user content logged, tests leave defaults alone
- [ ] P6 Network: HTTPS, credentials stay on their origin, every request times out
- [ ] P7 Command queue: long work is a background task, cancellable, no modal UI holding the queue
- [ ] P8 Interaction: Enter opens apps, destructive actions confirm, actions not hidden by stale state
- [ ] P9 IDs: stable, unique, qualified by connection record ID
- [ ] P10 Honesty: partial results visible; README/STORE claims match the code
- [ ] P11 Tests: offline XCTest target covering declaration, parsing, requests, applicability
- [ ] P12 Release hygiene: one CHANGELOG section, flat screenshots, in-repo links, 1024px icon, floors pass
- [ ] P13 Scope: small first release; no private app storage without a visible degraded state
- [ ] P14 Shared tooling: nothing outside the extension folder, or called out below

## Risk list

<!-- Tick every item this PR touches, with a word on what; leave all unticked if none applies.
Any ticked item sends the PR to the maintainer. -->

- [ ] New network host, or credentials sent somewhere new
- [ ] New app scripted via Apple Events, or new URL scheme invoked with user data
- [ ] New Keychain/secret/connection use, or new permission
- [ ] New destructive action
- [ ] Change outside the extension's own folder and its own store media
- [ ] Reading another app's private storage

## Verified

<!-- Gates run (make lint-extensions, the extension's tests, Release build, make test) and what you
checked by hand in Tuna. Say what you couldn't check. -->

- Tuna version:
- macOS version:
