#!/usr/bin/env bash
# scripts/review-queue: kind, review state, CI state and risk flags from canned gh JSON.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/review-queue"

OUTPUT="$("$ROOT/scripts/review-queue" --fixture "$FIXTURES/queue.json" --drafts "$FIXTURES/drafts" --json)"

python3 - "$OUTPUT" <<'PY'
import json, sys

rows = {r["number"]: r for r in json.loads(sys.argv[1])}
expected = {
    # New folder; Makefile, workspace and README only register it. No review; run awaits approval.
    21: ("admission", "needs review", "CI pending approval (run 2)", "reg"),
    # Own folder and own media. Reviewed head matches. Push runs are ignored.
    22: ("update", "waiting on contributor", "CI green", "-"),
    # Shared script and a non-registration Makefile edit. Head moved since the review.
    23: ("update", "needs re-review (last abcdef0)", "CI failed",
         "ci:scripts/upload-extension.sh,Makefile"),
    # No extension folder. A contributor's own "(Agent)" comment is not a review. Zero-job failure.
    24: ("tooling", "draft PR; needs review", "CI approval expired (run 6)",
         "ci:.github/workflows/ci.yml,scripts/run-xcodebuild"),
    # Another extension's media and a README row on an update. Contributor replied after review.
    25: ("update", "contributor replied", "CI running", "shared:media/screenshots/bar/1.png,README.md"),
    # No "Reviewed head:" line: the comment postdates the head commit. Registration on an update
    # is still a Makefile change. Hyphenated media slug belongs to MemeGeneratorExtension.
    26: ("update", "waiting on contributor", "CI none", "ci:Makefile"),
    # Unposted draft for this head. A README row for a different extension is not registration.
    27: ("admission", "draft awaiting OK", "CI none", "shared:README.md"),
}
failed = False
for number, want in expected.items():
    r = rows[number]
    got = (r["kind"], r["review"], r["ci"], r["flags"])
    if got != want:
        failed = True
        print(f"review-queue-test: #{number}: got {got}, want {want}", file=sys.stderr)
sys.exit(1 if failed else 0)
PY

echo "review-queue tests passed."
