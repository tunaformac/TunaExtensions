#!/usr/bin/env bash
# scripts/extension-risk on fixture diffs: each tests/fixtures/extension-risk/<case>.diff is applied
# to a repository built from base/, and the report must flag exactly what the case expects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/extension-risk"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tuna extension risk test.XXXXXX")"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for DIFF in "$FIXTURES"/*.diff; do
  CASE="$(basename "$DIFF" .diff)"
  REPO="$SANDBOX/$CASE"
  cp -R "$FIXTURES/base" "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -qm base
  git -C "$REPO" apply --index "$DIFF"
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -qm "$CASE"
  "$ROOT/scripts/extension-risk" --repo "$REPO" --quiet HEAD~1 HEAD >"$SANDBOX/$CASE.json"
done

python3 - "$SANDBOX" "$ROOT/scripts" <<'PY'
import json
import os
import sys

sandbox, scripts = sys.argv[1:]
sys.path.insert(0, scripts)
import extension_risk  # noqa: E402  (importable for other tools)

# case: ({extension: (kind, {(category, token)})}, [(flag, shared path)]); registration paths below
EXPECTED = {
    "clean-update": ({"AcmeExtension": ("update", set())}, []),
    "moved-code": ({"AcmeExtension": ("update", set())}, []),
    "new-host": ({"AcmeExtension": ("update", {
        ("network", "https://collect.example.net"),
        ("network", "mirror.acme.io"),
    })}, []),
    "apple-events": ({"AcmeExtension": ("update", {
        ("apple-events", "Finder"),
        ("apple-events", "NSAppleScript"),
    })}, []),
    "url-scheme": ({"AcmeExtension": ("update", {
        ("url-scheme", "things"),
        ("url-scheme", "NSWorkspace.shared.open("),
    })}, []),
    "keychain": ({"AcmeExtension": ("update", {
        ("credentials", "ExtensionConnectionDefinition("),
        ("credentials", "KeychainStore."),
        ("credentials", "secret"),
    })}, []),
    "permission": ({"AcmeExtension": ("update", {
        ("permission", "EventKit"),
        ("permission", "EKEventStore"),
        ("permission", "NSRemindersFullAccessUsageDescription"),
        ("permission", "reminders"),
    })}, []),
    "destructive": ({"AcmeExtension": ("update", {
        ("destructive", "isDestructive: true"),
        ("destructive", "ActionReviewPresentation("),
        ("destructive", "purge"),
    })}, []),
    "other-app-storage": ({"AcmeExtension": ("update", {
        ("other-app-storage", "Library/Group Containers/group.com.example.notes/Notes.sqlite"),
        ("other-app-storage", "homeDirectoryForCurrentUser"),
    })}, []),
    "build-script": ({"AcmeExtension": ("update", {
        ("build", "shellScript"),
        ("network", "https://example.org"),
    })}, []),
    "shared": (
        {"AcmeExtension": ("update", set()), "OtherExtension": ("update", set())},
        [("ci", "Makefile"), ("shared", "README.md"), ("shared", "media/screenshots/somebody-else/1.svg")],
    ),
    "admission": (
        {"NewExtension": ("admission", {("network", "https://api.new.example.com")})},
        [],
    ),
    # Registration that also drops another extension or edits other rows isn't registration.
    "admission-overreach": (
        {"NewExtension": ("admission", set())},
        [("ci", "Makefile"), ("shared", "README.md"), ("ci", "scripts/release.sh")],
    ),
}
# Cases whose hits must be exactly the expected set; the rest must include it.
EXACT = {"clean-update", "moved-code", "shared", "destructive", "build-script"}
REGISTRATION = {
    "admission": ["Makefile", "README.md", "TunaExtensions.xcworkspace/contents.xcworkspacedata"],
}

failures = []
cases = {name[:-5] for name in os.listdir(sandbox) if name.endswith(".json")}
if cases != set(EXPECTED):
    failures.append(f"fixture cases {sorted(cases)} don't match expectations {sorted(EXPECTED)}")

for case in sorted(cases & set(EXPECTED)):
    with open(os.path.join(sandbox, f"{case}.json"), encoding="utf-8") as fh:
        report = json.load(fh)
    expected_extensions, expected_shared = EXPECTED[case]
    got = {e["dir"]: e for e in report["extensions"]}
    if set(got) != set(expected_extensions):
        failures.append(f"{case}: extensions {sorted(got)}, expected {sorted(expected_extensions)}")
        continue
    for directory, (kind, hits) in expected_extensions.items():
        ext = got[directory]
        if ext["kind"] != kind:
            failures.append(f"{case}: {directory} kind {ext['kind']}, expected {kind}")
        found = {(h["category"], h["token"]) for h in ext["hits"]}
        missing = hits - found
        if missing:
            failures.append(f"{case}: {directory} missed {sorted(missing)}; found {sorted(found)}")
        if case in EXACT and found - hits:
            failures.append(f"{case}: {directory} unexpected hits {sorted(found - hits)}")
        if ext["clean_update"] != (kind == "update" and not found):
            failures.append(f"{case}: {directory} clean_update is {ext['clean_update']}")
        for hit in ext["hits"]:
            if (hit["category"], hit["token"]) in hits and hit["rule"] not in ("entitlements", "binary"):
                if not hit["evidence"]:
                    failures.append(f"{case}: {directory} hit {hit['token']} has no evidence")
    shared = sorted((item["flag"], item["path"]) for item in report["shared"])
    if shared != sorted(expected_shared):
        failures.append(f"{case}: shared {shared}, expected {sorted(expected_shared)}")
    registration = sorted(item["path"] for item in report["registration"])
    if registration != sorted(REGISTRATION.get(case, [])):
        failures.append(f"{case}: registration {registration}, expected {REGISTRATION.get(case, [])}")

# Media ownership follows the policy's slug only.
acme = extension_risk.Extension("AcmeExtension", "com.brnbw.tuna.plugins.acme")
terminal = extension_risk.Extension("OpenTerminalHereExtension", "com.brnbw.tuna.plugins.open-terminal-here")
for path, owner in [
    ("AcmeExtension/Info.plist", "AcmeExtension"),
    ("media/screenshots/acme/1.png", "AcmeExtension"),
    ("media/icons/acme.png", "AcmeExtension"),
    ("media/screenshots/com.brnbw.tuna.plugins.acme/1.png", None),
    ("media/screenshots/acme.png", None),
    ("media/screenshots/open-terminal-here/1.png", "OpenTerminalHereExtension"),
    ("media/screenshots/tuna-acme/1.png", None),
    ("media/icons/README.md", None),
    ("Makefile", None),
]:
    actual = extension_risk.path_owner(path, [acme, terminal])
    if actual != owner:
        failures.append(f"path_owner({path}) is {actual}, expected {owner}")

if failures:
    print("extension-risk-test: " + "\n  ".join(failures), file=sys.stderr)
    raise SystemExit(1)
print(f"extension-risk-test: {len(cases)} fixture diffs classified as expected")
PY
