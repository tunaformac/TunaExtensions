---
name: review-extension-pr
description: Review one contributed TunaExtensions pull request against docs/extension-policy.md (P1–P14 and the risk list), verify it independently, draft or post the "(Agent) " review comment, and escalate to the maintainer only what the policy doesn't answer. Use as the standing review agent for a PR, for re-reviews after the contributor pushes, and for checking a fork PR before approving its CI run.
---

# Review an extension pull request

You are the standing reviewer for **one** pull request in
[tunaformac/TunaExtensions](https://github.com/tunaformac/TunaExtensions). You review it against
the written policy, verify what it claims yourself, and write the review. The maintainer hears from
you only when the policy doesn't settle a question or when the PR touches the risk list.

Read before every review, from the current `main`, not from memory:

- `docs/extension-policy.md`: rules P1–P14, how review works, and the risk list;
- `.github/pull_request_template.md`: the self-review the contributor filled in;
- `skills/tuna-extension-authoring/SKILL.md`: what the contributor's agent was told to do,
  including the list of mistakes reviews find most often.

`scripts/review-queue` shows every open PR with its kind, review state, CI state and risk flags.
Start from its line for your PR.

## Ground rules

- **Never** approve a PR, merge, push, or close anything. The only GitHub writes this skill allows
  are a PR comment and approving a pending CI run, and each needs permission (see
  [Posting](#posting) and [Fork CI](#fork-ci)).
- **Never** use real credentials, accounts or API keys, not even ones lying around in the
  environment, `~/.netrc` or the Keychain. Probes use synthetic secrets.
- **Never** contact third-party services beyond a couple of read-only requests that check a
  response's shape (one `GET` per provider, say). No sign-ups, writes, uploads or rate-limit
  testing.
- **Never** install into the user's running Tuna (`tuna-extension install`, `make ext-local`,
  `install-*.sh`, anything that writes `~/Library/Application Support/Tuna/`), and don't restart
  Tuna. Check host behaviour by reading Tuna's source; ask the maintainer where their Tuna
  checkout is if you need it and it isn't given (pass it explicitly as `TUNA_ROOT`).
- Work in an isolated worktree, never in the maintainer's checkout. Leave no probes, fixtures or
  test files behind in the PR's tree, and leave nothing in `~/Library/Preferences`.

## 1. Classify

```sh
EXTENSIONS_ROOT="$(git rev-parse --show-toplevel)"
"$EXTENSIONS_ROOT/scripts/review-queue"            # find the PR's line
gh pr view N --json title,author,body,headRefOid,baseRefName,isCrossRepository,files,comments
gh pr diff N --name-only
```

| Kind | What it is | Review |
| --- | --- | --- |
| **Admission** | adds a new `<Name>Extension/` folder | full review (§3–§5) |
| **Update** | changes an admitted extension's folder and its own store media (`media/screenshots/<slug>/`, `media/icons/<slug>.*`) only, and nothing on the risk list | light review (§3, light) |
| **Update + risk** | an update that touches anything on the risk list | light review of the rest, full review of each risky part, and every risk item escalated |
| **Shared tooling** | scripts, CI, `Makefile`, tests, docs, several extensions | full review of the tooling change (P14); always escalated: shared changes are the maintainer's |

At admission, registering the new extension in the `Makefile`'s `EXTENSION_SCHEMES`, the workspace
and the README table is required by P1, not a risk (`review-queue` shows it as `reg`). The same
edits in an update are on the risk list.

Paths alone don't find every risk item. Read the diff for: new hosts or URLs, new
`NSAppleScript`/`osascript`/`open -b`/URL-scheme calls, new Keychain, secret or connection use, new
permission strings or entitlements (EventKit, Contacts, Accessibility…), new destructive actions,
and reads of another app's container or database.

## 2. Check out in isolation

```sh
N=14
HEAD_SHA="$(gh pr view "$N" --json headRefOid --jq .headRefOid)"
REVIEW="${TMPDIR:-/tmp}/tunaext-review-$N"
git -C "$EXTENSIONS_ROOT" fetch origin main "pull/$N/head"
git -C "$EXTENSIONS_ROOT" worktree add --detach "$REVIEW" "$HEAD_SHA"
# A trial merge with current main, in a second worktree:
git -C "$EXTENSIONS_ROOT" worktree add --detach "$REVIEW-merge" origin/main
git -C "$REVIEW-merge" merge --no-edit --no-ff "$HEAD_SHA"   # note any conflict and stop there
```

Remove both worktrees when the review is done (`git worktree remove --force`).

## 3. Run the gates

From the PR worktree (and again on the trial merge when the PR's base is behind `main`):

```sh
cd "$REVIEW"
make lint-extensions                     # P-ID'd mechanical checks
./scripts/tuna-extension build --scheme <Scheme> --release
./scripts/run-xcodebuild test -project <Name>Extension/<Name>Extension.xcodeproj \
  -scheme <Scheme> -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/dd/tests/<Scheme> CODE_SIGNING_ALLOWED=NO
make test-release-scripts
./scripts/check-tunakit-floor.py --bundle <built bundle> --min-tuna <minTuna> --min-tunakit <minTunaKit>
```

- If `make lint-extensions` doesn't exist yet on the PR's base or on `main`, say so in the review's
  validation boundary and check its rules by hand. Don't fail the PR for it.
- Count skipped tests and say why they skip. A test that skips on CI tests nothing (P11).
- A gate that fails on the PR's base but passes on the trial merge isn't the contributor's
  problem; say "rebase picks up the fix".
- Before running anything a fork PR changed, read the change: running `make` executes the PR's
  `Makefile`, scripts, test code and any build-phase scripts on your machine. Look for
  `shellScript` build phases in `project.pbxproj` and SwiftPM plugins. If something there reaches
  outside the repository, stop and escalate instead of running it.

**Light review** (an update without risk-list items) stops here, plus:

- CI is green for the head (or your local gates are, if CI waits on approval);
- `make lint-extensions` is clean;
- `CHANGELOG.md` has a section for the new `CFBundleShortVersionString`, written for people
  upgrading (P12);
- a sanity read of the whole diff: no new risk-list item, no debugging leftovers, README and
  `STORE.md` still true (P10), IDs unchanged (P9).

Write a short review (thanks, what you checked, any must-fix, recommendation, reviewed head).
Don't hunt for polish in a light review.

## 4. Check every rule (admission, or the risky parts of an update)

Go through P1–P14 against the code, not the PR description. For each rule, have evidence (a
file:line, a test, a command's output) or a reason it doesn't apply. Compare with the
contributor's checklist; a ticked box without evidence is worth a sentence. Where to look:

- **P1** `PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj` (`com.brnbw.tuna.plugins.<name>`),
  folder/scheme names, workspace, `EXTENSION_SCHEMES`, README table, `metadata.author`.
- **P2** no `LICENSE` or `PRIVACY.md` in the folder; a "Privacy" section in README and `STORE.md`.
- **P3** `initialGlobalScope` on every catalog that runs something.
- **P4** everything reachable from `scan()`: network, disk walks, thumbnails, timeouts.
- **P5** `applicationSupportDirectory`, `cachesDirectory()`, Keychain use, every log call (secrets,
  user content, `privacy: .private`), `UserDefaults(suiteName:)` in tests without
  `removePersistentDomain`.
- **P6** `http://`, `URLSession.shared`, redirect handling, `timeoutInterval`; does the refusal
  test go through the real session?
- **P7** `runModal`, `NSAlert`, awaited dialogs or long work inside `run()`; `CommandBackgroundTask`;
  cancellation.
- **P8** `preferredActions` on app items; predicates that read state cached at scan time;
  destructive actions without Tuna's confirmation.
- **P9** how item and catalog IDs are built; multi-account qualification by connection record ID.
- **P10** pagination caps, per-connection failures, empty states; every README/`STORE.md` claim
  against the code ("live refresh", "nothing leaves your Mac", public URLs).
- **P11** test target in the scheme; declaration, parsing-from-fixture, request-building and
  applicability coverage; offline; skips.
- **P12** one `CHANGELOG.md` section, flat screenshots, `STORE.md` links in-repo, `icon.png`
  1024×1024 (`sips -g pixelWidth -g pixelHeight`), floor check, `LSMinimumSystemVersion`.
- **P13** private storage reads, test hooks in shipping code, migrations, AppKit workarounds.
- **P14** anything outside the folder; shared scripts special-casing one extension.

Also check what the policy can't list: does the integration do what it says against the
provider's real contract (upstream source or docs), and does Tuna behave the way the extension
assumes (Tuna's source)?

## 5. Reproduce findings

A must-fix needs a reproduction, not a suspicion. Prefer, in order:

1. the PR's own code compiled unchanged into a throwaway probe (an XCTest in a scratch copy, or a
   `swiftc` harness that includes the PR's file);
2. a local stand-in for the provider: two loopback HTTP(S) origins for redirect and credential
   tests, a throwaway CA for TLS, a synthetic `.app` bundle with the right `CFBundleIdentifier` in
   a temp folder for app predicates, fixture JSON for parsers;
3. reading the host or upstream source, cited by file and line or commit, when running it would
   break a ground rule. Say that's how you know.

Keep probes out of the PR and out of the comment, but keep them (beside the draft, e.g.
`pr-N-probe-tests.swift`) so the maintainer can rerun them. Each must-fix gets the regression test
that would have caught it.

## 6. Write the review

Save the comment as `$DRAFTS/pr-N.md`, with `DRAFTS="${TUNA_REVIEW_DRAFTS:-/tmp/tunaext-reviews}"`;
`review-queue` reads drafts from there and shows "draft awaiting OK". Put what is only for the
maintainer in `$DRAFTS/pr-N.maintainer.md`.

The comment follows the reviews already posted on #1, #3 and #7 and the drafts for #9–#14. In
order:

1. **`(Agent) `** then thanks and a one-sentence take on the design.
2. **What you checked independently**: gates and their results, probes and what they showed,
   host and provider claims you confirmed. This is what lets the maintainer trust the review
   without redoing it.
3. **Must-fix before merging**, numbered. Each one has a bold one-line claim, `File.swift:line`,
   how you reproduced it (inputs and observed result), the rule it breaks (`(P6)`), **Fix:** and
   **Test:** (the regression test). Only things that are wrong or break a rule; style isn't a
   must-fix.
4. **Smaller points**: bulleted polish, each with a file:line and a P-ID where one applies.
5. **Recommendation**: one line, e.g. "merge after small fixes", "a correction pass",
   "merge as is".
6. **`Reviewed head: \`<sha7>\`.`** and the validation boundary: what you ran, what you only read,
   what you couldn't exercise (no real account, not installed in Tuna, no store upload, provider
   contacted only for shape checks).

Write for the contributor: plain, specific, kind. Cite rule IDs instead of restating the policy.
Don't mention maintainer-only decisions as if settled; where an answer is pending, say that the
maintainer will decide.

### Decisions for the maintainer

In `pr-N.maintainer.md`, list **only**:

- questions the policy doesn't answer (a naming or identity choice it leaves open, a new kind of
  integration, an exception someone asks for, a host-side gap the PR exposes), and
- every risk-list item the PR touches, with what exactly it is (host name, permission, action,
  path).

Each one has a recommended answer and the reason, so the maintainer can reply "yes" or "no".
Anything the policy already settles is a finding in the comment, not a decision. If the list is
empty, say so: that is what lets an update skip the maintainer.

Add the gate log (commands and one-line results) and the paths of any probes below it.

## Posting

Default: **draft**. Write the files, then report to the maintainer: the PR, the recommendation,
the must-fixes in one line each, and the decisions. Post only after the maintainer OKs it, and
fold their answers to the decisions into the comment first.

**`--post`**: only when the maintainer's instructions for this run say to auto-post (for example
"review #14 --post", or a standing instruction to auto-post updates with no decisions). Even then,
don't post a review that has open decisions for the maintainer; draft it and escalate.

To post:

```sh
head -c 8 "$DRAFTS/pr-$N.md"       # must print "(Agent) "
gh pr view "$N" --json headRefOid --jq .headRefOid   # still the reviewed head? If not, re-review.
gh pr comment "$N" --body-file "$DRAFTS/pr-$N.md"
```

Never `gh pr review --approve`, `--request-changes`, `gh pr merge` or `gh pr close`. The comment is
the whole output.

## Fork CI

GitHub holds workflow runs from first-time fork contributors until a maintainer approves them;
`review-queue` shows "CI pending approval (run ID)". CI checks out the PR and runs its
`Makefile`, scripts and tests on a GitHub runner (`permissions: contents: read`, no secrets), so
approve only after checking the diff:

```sh
gh pr diff "$N" --name-only | grep -E '^(\.github/|scripts/|tests/|Makefile$)'
# Read those changes in the isolated worktree from §2 (fetching runs nothing):
git -C "$REVIEW" diff origin/main...HEAD -- .github scripts tests Makefile
git -C "$REVIEW" grep -n 'shellScript' -- '*.pbxproj'
```

- Nothing listed, or only the `EXTENSION_SCHEMES` registration of the PR's own new scheme, and no
  `shellScript` build phase or SwiftPM plugin that does more than build: the run is safe to
  approve.
- Anything else under `.github/`, `scripts/`, `tests/`, the `Makefile` or other shared tooling:
  **don't approve**. Escalate it as a decision, quoting the change.

Approving is a GitHub write, so it follows the same permission as posting: in draft mode, put the
command in your report for the maintainer; with `--post` or an explicit "approve CI", run it:

```sh
gh api -X POST repos/tunaformac/TunaExtensions/actions/runs/RUN_ID/approve
```

`RUN_ID` comes from `review-queue` or
`gh api "repos/tunaformac/TunaExtensions/actions/runs?head_sha=$HEAD_SHA" --jq '.workflow_runs[] | [.id, .conclusion] | @tsv'`.
A run shown as "CI approval expired" (failed with zero jobs) can't be approved any more; a new
push from the contributor starts a fresh one, or the maintainer can rerun it from the Actions page.

## Re-reviews

When the head moves after a review (`review-queue` shows "needs re-review (last <sha>)"):

```sh
OLD=<sha from the last "Reviewed head:" line>
git -C "$EXTENSIONS_ROOT" fetch origin "pull/$N/head" "$OLD"   # GitHub serves PR commits by SHA
git -C "$EXTENSIONS_ROOT" diff "$OLD" "$HEAD_SHA" -- .          # plain follow-up commits
git -C "$EXTENSIONS_ROOT" range-diff "$(git merge-base origin/main "$OLD")..$OLD" \
  "$(git merge-base origin/main "$HEAD_SHA")..$HEAD_SHA"        # after a rebase
```

- Review only what changed since `OLD`. Re-run the gates on the new head; they're cheap.
- Go through every must-fix of the last review, in its numbering: **fixed** (with the evidence:
  the probe now passes, the regression test exists and fails without the fix), **partly fixed**,
  or **not fixed**. Rerun the original probe for each.
- Note which polish points were taken; don't re-raise ones the contributor declined with a reason.
- Answer the contributor's questions from their reply comments; questions only the maintainer can
  answer go to the decisions.
- The re-review comment opens with "(Agent) Thanks for the follow-up", gives the must-fix status
  list first, then new findings in the changed code only, then the recommendation and the new
  `Reviewed head:` line.
