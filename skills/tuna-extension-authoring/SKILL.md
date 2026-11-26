---
name: tuna-extension-authoring
description: Design and build Tuna extensions with a mandatory discovery, design-packet, and user-approval gate.
---

# Tuna Extension Authoring

Use this skill for new Tuna extensions and material extension redesigns. Work in a branch of
[TunaExtensions](https://github.com/tunaformac/TunaExtensions), which is the source of truth for
current examples and the repository where completed extensions are submitted by pull request.

Every extension must follow the contribution policy, `docs/extension-policy.md`: rules P1–P14 and
the risk list. Read it before designing; the design packet and the self-review below cite its rule
IDs.

## Hard gate: discover, map, then ask

Do not scaffold or edit implementation files until all five steps are complete:

1. **Inventory current examples.** In the TunaExtensions checkout, enumerate and read every
   `*Extension.swift` declaration. Then inspect representative catalog, item, action, provider, and
   test files for every relevant shape in `docs/extension-authoring.md`. Do not trust this skill's
   taxonomy without refreshing it from the checkout.
2. **Inspect the integrated product.** Read its public docs and source when available. Verify bundle
   identifiers, storage or API contracts, permissions, write behavior, native terminology, icons,
   quotas, and live-update signals. If source is unavailable, say which claims come from docs or
   observation. Never guess credentials, scopes, or destructive behavior.
3. **Map the product to Tuna.** Decide its catalogs, types, browse hierarchy, actions, targets,
   connections/settings, app enrichments, lifecycle, and presentation.
4. **Present the extension design packet** below. Include alternatives and a recommendation wherever
   the mapping is uncertain.
5. **Explicitly ask for approval.** If the agent has a structured question tool, use it with an
   approval option and revision options. Otherwise ask plainly. **Stop and wait. Do not scaffold or
   implement until the user approves the mapping.**

This gate is implementation work, not optional planning. Approval must cover the catalog/default
matrix, provider access, credentials and scopes, app enrichments, and every write or destructive
action. If discovery changes an approved mapping materially, present the delta and ask again.

## Extension design packet

Keep the packet compact but complete:

1. User jobs and explicit non-goals.
2. Provider contract: local file/database, CLI, framework, URL scheme/Apple Events, or API; include
   permissions, privacy, quotas, writes, destructive operations, and refresh signals.
3. Catalog matrix: stable ID, name, role, presentation, default enablement, global scope (P3:
   catalogs that do something when run start at `.none`), startup/deferred behavior (P4), browse
   root, and contents. State exactly which concrete items appear in global search.
4. Type/item model: stable IDs, inheritance, search fields, text/copy representation, timestamps,
   sorting, and hierarchy.
5. Action grammar: title, subject, optional/required target, target source and preparation policy,
   execution policy, result form, confirmation, and ellipsis choice. Never use an ellipsis when Tuna
   will not enter a target pane; refresh the positive naming convention from current examples.
6. App integration: verified bundle IDs, browse destinations, action catalogs, and predicates.
7. Authentication/settings and multi-account behavior.
8. Loading, empty, auth, degraded, error, and partial-failure states; live refresh and caching.
9. Presentation: extension accent, rounded catalog icons, list/grid, previews, and Quick Look.
10. Compatibility floors, tests, README/privacy notes, dev install, packaging, and manual validation.
11. Policy fit: any rule (P1–P14) the design can't meet, and every risk-list item it touches.
    Flag these now; they are what admission review looks at hardest.

## Concept map

- **Catalogs are nouns and discovery surfaces.** A catalog may expose indexed content, a browse or
  live-search entry, commands, a finite target source, or hidden plumbing. Every declaration chooses
  `.source`, `.browseRoot(contents:)`, `.liveSearch`, `.snapshot`, or `.hidden` deliberately.
- **Action catalogs are verbs.** `ActionCatalog` is a sibling of `Catalog`: it declares `actions`,
  has no scan lifecycle or source toggle, and belongs in `actionCatalogs`.
- **Browse roots are navigation.** Prefer `BrowseCatalogItem`, `DeferredBrowseCatalogItem`, or
  `ScopedSearchBrowseCatalogItem`; hand-roll `CatalogHierarchyNode` only for domain hierarchy the
  standard entries cannot express.
- **Types are capabilities.** Inheritance from text, URL, file, directory, application, or other
  semantic types controls generic actions. It is product behavior, not decoration.
- **Targets are selectable operands.** A target may be a destination, second object, or one typed
  text operand; it is not a substitute for arbitrary multi-field form UI. Declare requirement,
  allowed types, predicate, catalog scope/preparation, batching, headless eligibility, execution
  policy, and result form deliberately.
- **App enrichment is contextual navigation.** Browse enrichment adds domain contents to an app
  result; action enrichment orders additive app-specific verbs. Validate bundle IDs in predicates.
- **Connections/settings model access.** Use OAuth, a PAT/custom connection, a Keychain-backed secret,
  or an ordinary setting according to provider ownership and multi-account needs.
- **Lifecycle models cost and freshness.** Decide startup scan, deferred loading, retained-state
  release, partial failures, observation, cache invalidation, and when to call `reportScanFinished()`.
- **Previews communicate kind.** Browse roots use Tuna's colored rounded catalog icon; leaves use
  native app, file, URL, symbol, thumbnail, or Quick Look previews.

## After approval

1. Create a branch in TunaExtensions. Copy the closest existing extension project for project wiring,
   rename it consistently (P1: bundle ID `com.brnbw.tuna.plugins.<name>`, folder and scheme
   `<Name>Extension`), remove all example-specific behavior, and register it in
   `TunaExtensions.xcworkspace`, `EXTENSION_SCHEMES` in the `Makefile`, and the README table. Use
   the real extensions as recipes for browse, provider, framework, action, and connection
   variants; do not inherit machinery absent from the approved design.
2. Keep stable catalog/item/action/type/provider/setting IDs. Separate content, browse companions,
   and target-only sources when their global-search semantics differ.
3. Preserve source-native data and formatting for writes. Use Tuna-owned review/confirmation for
   destructive actions. Never launch unowned work and immediately return success.
4. Add an offline XCTest target (P11) with declaration and catalog-shape tests, action-grammar
   tests, request-building tests, and provider/parser fixtures at the narrowest useful boundary.
   Include honest auth, loading, empty, degraded, and error items.
5. Update the extension README with setup, permissions, privacy, quotas, writes, and limitations.
   Privacy goes in its "Privacy" section and `STORE.md`, never a separate `PRIVACY.md` or
   `LICENSE` (P2).

## Validation

Prerequisites: macOS 15+, Xcode, Tuna installed, `rg`, and network access for the released TunaKit
Swift package. Run the shared commands from the TunaExtensions repository root:

```bash
./scripts/tuna-extension build --scheme ExampleExtension --release
./scripts/tuna-extension install --scheme ExampleExtension --restart
./scripts/tuna-extension logs --last 20m
make test
```

Manually verify source defaults and global scope, browse behavior, catalog icon shape, app
enrichment, action subject/target grammar, writes and confirmation, live refresh, empty/auth/error
states, and extension logs. Test the oldest Tuna, TunaKit, and macOS versions claimed. Packaging,
store upload, and release commands are maintainer responsibilities.

## Self-review before the pull request

Do not open a pull request until this is done. It applies to new extensions and to updates.

1. **Run the gates** from the repository root and fix every failure:

   ```bash
   make lint-extensions          # mechanical policy checks
   ./scripts/tuna-extension build --scheme ExampleExtension --release
   make test                     # repository checks and all extension tests
   ```

2. **Check every rule** in `docs/extension-policy.md` against the code, not against memory of the
   design. For each of P1–P14, find the evidence (a file and line, a test, a command's output) or
   decide it doesn't apply and say why. Fix what fails; if something can't be fixed, say so in the
   pull request. The mistakes reviews find most often:
   - P3: a command catalog left at the default `.all` global scope.
   - P4: template lists or thumbnails downloaded during the launch scan.
   - P5: caches in Application Support; test `UserDefaults` suites left in `~/Library/Preferences`.
   - P6: a redirect test that calls the delegate directly instead of going through the session.
   - P7: a pairing or sign-in dialog awaited inline instead of returned as a background task.
   - P8: `preferredActions` on an app item; actions hidden because of state cached at scan time.
   - P10: an empty success where an explanation belongs; README promises (privacy, live refresh)
     the code doesn't keep.
   - P11: tests that skip without the real app installed, or no test target at all.
   - P12: two CHANGELOG sections for a first release; screenshots in a subfolder; links to a
     personal repository.
   - P14: a fix to shared scripts or test fixtures bundled into the extension's pull request.
3. **Check the risk list.** Compare the branch with its base (`git diff --stat origin/main...HEAD`)
   and name every risk-list item it touches. Any file outside the extension's folder counts.
4. **Fill in `.github/pull_request_template.md`** as the pull request description: what and why,
   the P1–P14 checklist (each ticked or "n/a because…"), the risk-list items, the gates you ran,
   what you verified by hand, what you couldn't verify, and the Tuna and macOS versions you used.
   Keep it short; the evidence is for the reviewer to spot-check, not a transcript.

## Public references

- `docs/extension-policy.md` — contribution rules P1–P14, the risk list, and how review works
- `docs/extension-authoring.md` — current shapes, examples, setup, and recipe index
- `README.md` — repository build and validation commands
- <https://tunaformac.com/docs/extension-development> — public API and distribution documentation
- <https://github.com/tunaformac/TunaKit> — released binary package and changelog

Treat TunaKit as public beta: pin up to the next minor and read its changelog before updating. Do
not use undocumented symbols merely because they are visible in the binary.
