#!/usr/bin/env python3
"""Classify a git range against the extension policy's risk list.

`scripts/extension-risk BASE HEAD` is the command; this module is the library behind it, so other
tools can import it:

    sys.path.insert(0, "<repo>/scripts")
    import extension_risk
    report = extension_risk.classify(repo_root, "origin/main", "pull/9/head")
    owner = extension_risk.path_owner(path, extensions)  # path-only flagging

The range is diffed from the merge base of BASE and HEAD (like `git diff BASE...HEAD`), so changes
that landed on BASE meanwhile never count against HEAD.

Two kinds of finding:

* **Shared changes** (path rule): any changed path outside every extension's folder and its own
  store media (`media/screenshots/<slug>/`, `media/icons/<slug>.*`). Media whose slug doesn't
  belong to exactly one extension counts as shared.
* **Risk hits** (content rules), per extension: the rules below run over the extension's files at
  the merge base and at HEAD, and a hit is something HEAD has that the base didn't. Rules are
  either `new` (a token, such as a host or an Apple Events target, absent from the base) or `more`
  (a marker, such as `isDestructive: true`, that occurs more often than in the base). Moving code
  around therefore doesn't count; adding a second destructive action does. Evidence is the added
  diff lines that produced the token.

The content rules are best effort and deliberately loose: a false positive costs the maintainer a
look, a miss ships unreviewed code under the store key. Markdown and images are not scanned (but a
new `warnings:` entry in STORE.md is). Tests are scanned like any other file.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import os
import re
import subprocess
import sys
from typing import Iterable

SCHEMA_VERSION = 1

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".heic", ".icns", ".tiff", ".pdf")
UNSCANNED_SUFFIXES = IMAGE_SUFFIXES + (".md",)
# Xcode scheme and workspace files reference "container:" paths.
XCODE_METADATA = re.compile(r"\.(?:xcscheme|xcworkspacedata)$")

# --------------------------------------------------------------------------------------------
# Content rules
# --------------------------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Rule:
    id: str
    category: str
    mode: str  # "new": token absent at base; "more": token occurs more often than at base
    pattern: re.Pattern
    message: str
    files: str = "code"  # "code": every scanned file; "plist", "pbxproj", "store": only those
    token: str = ""  # fixed token for marker rules; empty means the first group (or the match)
    exclude: "re.Pattern | None" = None  # tokens to ignore
    skip_files: "re.Pattern | None" = None  # paths the rule doesn't scan


def _rx(pattern: str, flags: int = 0) -> re.Pattern:
    return re.compile(pattern, flags)


def _apis(category: str, rule_id: str, mode: str, names: Iterable[str], message: str) -> Rule:
    """One rule matching any of names as a whole word; the token is the name."""
    alternatives = []
    for name in sorted(names, key=len, reverse=True):
        before = r"(?<![A-Za-z0-9_])" if re.match(r"\w", name) else ""
        after = r"(?![A-Za-z0-9_])" if re.search(r"\w$", name) else ""
        alternatives.append(before + re.escape(name) + after)
    return Rule(rule_id, category, mode, _rx("(" + "|".join(alternatives) + ")"), message)


# File extensions that look like TLDs but are almost always file names in Swift sources.
FILE_LIKE_TLDS = {
    "png", "jpg", "jpeg", "gif", "json", "plist", "txt", "md", "swift", "sqlite", "db",
    "framework", "bundle", "scpt", "html", "css", "js", "xml", "log", "zip", "pdf", "csv", "yml",
    "yaml", "toml", "svg", "webp", "mp3", "mp4", "mov", "m4a", "heic", "icns", "strings", "xib",
    "storyboard", "dylib", "sh", "py", "rb", "plugin", "appex", "tunaextension", "wal", "shm",
    "sqlite3", "bin", "dat", "lproj", "xcassets", "pem", "der", "cer", "keychain", "kdbx", "enc",
}
REVERSE_DNS_ROOTS = {
    "com", "org", "net", "io", "dev", "app", "co", "me", "de", "dk", "pl", "fr", "uk", "nl", "se",
    "no", "fi", "ch", "at", "be", "it", "es", "jp", "cn", "ru", "us", "ca", "au", "eu", "info",
    "md", "is", "sh", "ai", "tv", "fm", "so", "ly", "cc", "group",
}
# The plist DOCTYPE names apple.com; it's not a request.
PLIST_BOILERPLATE = re.compile(r"^\s*<!DOCTYPE ")
# SF Symbol names ("person.crop.circle.badge.plus") look like domains.
SYMBOL_CONTEXT = re.compile(r"symbol|systemName|SFSymbol", re.IGNORECASE)

RULES: list[Rule] = [
    # -- network: new hosts and base URLs ---------------------------------------------------
    Rule(
        "network-origin", "network", "new",
        _rx(r"\b((?:https?|wss?|ftp)://(?:[^/\s\"'<>)\\]|\\\([^)]*\))+)", re.IGNORECASE),
        "new URL origin",
    ),
    Rule(
        "network-host", "network", "new",
        _rx(r"(?:\.host\s*=|\bhost\s*:|\bhost\s*=)\s*\"([^\"]+)\""),
        "new host assigned in code",
    ),
    Rule(
        "network-domain", "network", "new",
        _rx(r"\"((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,24})(?::\d+)?(?:/[^\"]*)?\""),
        "new domain-like string",
    ),
    _apis(
        "network", "network-api", "new",
        ["URLSession", "URLRequest", "CredentialedHTTPClient", "NWConnection", "NWListener",
         "URLSessionWebSocketTask", "CFSocket", "socket(", "getaddrinfo", "WKWebView"],
        "first network API use in this extension",
    ),
    # -- Apple Events and URL schemes --------------------------------------------------------
    Rule(
        "apple-events-target", "apple-events", "new",
        _rx(r"tell\s+(?:application|app)\s+(?:id\s+)?\\?\"((?:[^\"\\]|\\\()+?)\\?\""),
        "new Apple Events target",
    ),
    Rule(
        "apple-events-jxa-target", "apple-events", "new",
        _rx(r"\bApplication\(\s*\\?\"([^\"\\]+)\\?\"\s*\)"),
        "new JavaScript for Automation target",
    ),
    Rule(
        "apple-events-bundle-target", "apple-events", "new",
        _rx(r"(?:NSAppleEventDescriptor|SBApplication)\(\s*bundleIdentifier:\s*\"([^\"]+)\""),
        "new Apple Events target",
    ),
    _apis(
        "apple-events", "apple-events-api", "new",
        ["NSAppleScript", "OSAScript", "NSUserAppleScriptTask", "osascript", "NSAppleEventDescriptor",
         "SBApplication", "AESend", "AEDeterminePermissionToAutomateTarget"],
        "first Apple Events API use in this extension",
    ),
    Rule(
        "url-scheme", "url-scheme", "new",
        _rx(r"\"([a-z][a-z0-9+.-]{1,40}):(?=[^\s\"])"),
        "new URL scheme",
        exclude=_rx(r"^(?:https?|wss?|ftp|file|data|about|blob)$"),
        skip_files=XCODE_METADATA,
    ),
    Rule(
        "url-scheme-components", "url-scheme", "new",
        _rx(r"\.scheme\s*=\s*\"([^\"]+)\""),
        "new URL scheme set on URLComponents",
        exclude=_rx(r"^(?:https?|wss?)$"),
    ),
    Rule(
        "url-scheme-interpolated", "url-scheme", "more",
        _rx(r"\"([a-z][a-z0-9+.-]{1,40}):[^\"]*\\\("),
        "more custom-scheme URLs built from interpolated data",
        exclude=_rx(r"^(?:https?|wss?|file|data)$"),
    ),
    _apis(
        "url-scheme", "url-open", "more",
        ["NSWorkspace.shared.open(", "URIOpener.open", "openURL(", "LSOpenCFURLRef", "LSOpenFromURLSpec"],
        "more call sites that open a URL (check the scheme and any user data in it)",
    ),
    # -- credentials: Keychain, connections, secrets ------------------------------------------
    _apis(
        "credentials", "credentials-api", "more",
        ["ExtensionConnectionDefinition(", "ExtensionConnectionStore(", "connectionDefinitions",
         "KeychainStore.", "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete",
         "kSecClass", "kSecAttrService", "kSecAttrAccessGroup", "SecKeychain", "secretValue(",
         "OAuthPKCEConfiguration", "OAuthAuthorizationCode", "Credential.bearer", "Credential.header",
         ".bearer(", "\"Authorization\"", "Bearer ", "Basic ", "x-api-key", "X-Api-Key",
         "client_secret", "clientSecret", "LAContext"],
        "more Keychain, connection, secret or credential uses",
    ),
    Rule(
        "credentials-kind", "credentials", "more",
        _rx(r"(?:type|kind)\s*:\s*\.(secret|oauth)\b"),
        "more secret settings or connections",
    ),
    # -- permissions -------------------------------------------------------------------------
    _apis(
        "permission", "permission-api", "new",
        ["EKEventStore", "EKReminder", "EKEvent", "requestFullAccessToEvents",
         "requestFullAccessToReminders", "requestWriteOnlyAccessToEvents", "CNContactStore",
         "CNContact", "PHPhotoLibrary", "PHAsset", "CLLocationManager", "AVCaptureDevice",
         "AVAudioRecorder", "AVAudioEngine", "SFSpeechRecognizer", "SCShareableContent",
         "SCStream", "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
         "CGWindowListCreateImage", "CGDisplayCreateImage", "AXIsProcessTrusted", "AXUIElement",
         "AccessibilityPermission", "AccessibilityEventTarget", "CGEvent.tapCreate",
         "CGEventTapCreate", "CGEventPost", "addGlobalMonitorForEvents", "IOHIDRequestAccess",
         "IOHIDManager", "CBCentralManager", "HMHomeManager", "UNUserNotificationCenter",
         "MPMediaLibrary", "INPreferences", "NEHotspot", "CWWiFiClient", "SMAppService",
         "kTCCService", "TCC.db"],
        "first permission-gated API use in this extension",
    ),
    Rule(
        "permission-import", "permission", "new",
        _rx(r"^\s*(?:@\w+\s+)*import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?"
            r"(EventKit|Contacts|ContactsUI|Photos|PhotosUI|CoreLocation|AVFoundation|Speech|"
            r"ScreenCaptureKit|ApplicationServices|CoreBluetooth|HomeKit|LocalAuthentication|"
            r"Security|ScriptingBridge|OSAKit|IOKit|SQLite3|Network|CoreWLAN|UserNotifications|"
            r"Carbon|WebKit|MediaPlayer|Intents|ServiceManagement|CoreGraphics)\b"),
        "new import of a framework behind a permission or private data",
    ),
    Rule(
        "permission-plist-key", "permission", "new",
        _rx(r"<key>((?:NS\w+UsageDescription)|LSApplicationQueriesSchemes|CFBundleURLTypes|"
            r"CFBundleURLSchemes|com\.apple\.[\w.-]+|NSAppTransportSecurity|"
            r"NSAllowsArbitraryLoads\w*|NSExceptionDomains)</key>"),
        "new privacy, entitlement or URL key in a plist",
        files="plist",
    ),
    Rule(
        "store-warning", "permission", "new",
        _rx(r"^warnings\s*:\s*\[([^\]]*)\]"),
        "new permission warning in STORE.md",
        files="store",
    ),
    # -- destructive actions -----------------------------------------------------------------
    Rule(
        "destructive-confirmation", "destructive", "more",
        _rx(r"isDestructive\s*:\s*true"), "more destructive confirmations", token="isDestructive: true",
    ),
    Rule(
        "destructive-role", "destructive", "more",
        _rx(r"role\s*:\s*\.destructive"), "more destructive roles", token="role: .destructive",
    ),
    Rule(
        "destructive-wording", "destructive", "more",
        _rx(r"\"[^\"\n]*\b(delete|remove|trash|erase|wipe|destroy|purge|uninstall|discard|kill|"
            r"revoke|reset|clear|overwrite|empty)\b[^\"\n]*\"", re.IGNORECASE),
        "more strings naming a destructive operation",
    ),
    _apis(
        "destructive", "destructive-api", "more",
        ["removeItem(", "trashItem(", "unlink(", "rmdir(", "\"DELETE\"", "rm -rf", "rm -r",
         "replaceItemAt(", "truncate(", "SecItemDelete", "ActionReviewPresentation("],
        "more calls that delete or overwrite data",
    ),
    # -- other apps' storage -----------------------------------------------------------------
    Rule(
        "other-app-storage-path", "other-app-storage", "new",
        _rx(r"\"([^\"\n]*(?:Library|Containers|Application Support|Preferences|Caches|Cookies|"
            r"Mobile Documents|CloudDocs|\.sqlite|\.db\b|\.plist|~/)[^\"\n]*)\""),
        "new path into Library storage or another app's data",
    ),
    _apis(
        "other-app-storage", "other-app-storage-api", "more",
        ["homeDirectoryForCurrentUser", "NSHomeDirectory", ".applicationSupportDirectory",
         ".libraryDirectory", ".cachesDirectory", ".documentDirectory", ".downloadsDirectory",
         ".desktopDirectory", "UserDefaults(suiteName:", "CFPreferencesCopyAppValue",
         "CFPreferencesCopyValue", "containerURL(forSecurityApplicationGroupIdentifier",
         "sqlite3_open", "contentsOfDirectory(", "enumerator(at:"],
        "more filesystem or defaults access outside the extension's own storage",
    ),
    # -- processes and dynamic code ----------------------------------------------------------
    _apis(
        "process", "process-api", "more",
        ["Process(", "CLIProcessRunner", "CLIProcessRequest", "executableURL", "launchPath",
         "posix_spawn", "NSTask", "system(", "popen(", "dlopen", "dlsym", "NSClassFromString",
         "perform(Selector", "NSSelectorFromString", "@_silgen_name", "Bundle(path:", "Bundle(url:",
         ".load()", "loadAndReturnError"],
        "more process launches or dynamic code loading",
    ),
    Rule(
        "process-executable", "process", "new",
        _rx(r"\"((?:/usr)?/s?bin/[^\"\s]+|/usr/local/[^\"\s]+|/opt/homebrew/[^\"\s]+|/Applications/[^\"]+)\""),
        "new executable or app path",
    ),
    # -- build, dependencies and identity ----------------------------------------------------
    Rule(
        "build-script", "build", "more",
        _rx(r"\bshellScript\s*="), "more build-phase scripts (they run during every build)",
        files="pbxproj", token="shellScript",
    ),
    Rule(
        "build-package-reference", "build", "new",
        _rx(r"\b(?:repositoryURL|relativePath)\s*=\s*\"?([^\";]+)\"?;"),
        "new Swift package dependency",
        files="pbxproj",
    ),
    Rule(
        "build-package-pin", "build", "new",
        _rx(r"\"location\"\s*:\s*\"([^\"]+)\""),
        "new pinned Swift package",
    ),
    Rule(
        "build-package-manifest", "build", "new",
        _rx(r"\.package\(\s*(?:url|path|name)\s*:\s*\"([^\"]+)\""),
        "new Swift package dependency",
    ),
    Rule(
        "build-linked-binary", "build", "new",
        _rx(r"\b([A-Za-z0-9_+-]+\.(?:framework|xcframework|dylib|a))\b"),
        "new linked framework or library",
        files="pbxproj",
        exclude=_rx(r"^(?:product-type|wrapper)\.framework$"),
    ),
    Rule(
        "build-settings", "build", "new",
        _rx(r"\b((?:OTHER_LDFLAGS|OTHER_SWIFT_FLAGS|OTHER_CFLAGS|LD_RUNPATH_SEARCH_PATHS|"
            r"FRAMEWORK_SEARCH_PATHS|LIBRARY_SEARCH_PATHS|CODE_SIGN_ENTITLEMENTS|"
            r"ENABLE_HARDENED_RUNTIME|SWIFT_INCLUDE_PATHS)\s*=\s*[^;]*);"),
        "new linker, entitlement or search-path build setting",
        files="pbxproj",
    ),
    Rule(
        "build-scheme-action", "build", "more",
        _rx(r"(ShellScriptAction|scriptText\s*=)"),
        "more scheme pre- or post-action scripts (they run during builds and tests)",
        files="xcscheme", token="scheme script",
    ),
    Rule(
        "build-plugin", "build", "more",
        _rx(r"(\.plugin\(|\.macro\(|\bbuildCommand\b|\bprebuildCommand\b|\bXCSwiftPackageProductDependency\b)"),
        "more Swift package plugins, macros or products",
    ),
    Rule(
        "identity", "identity", "new",
        _rx(r"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*\"?([^\";]+)\"?;"),
        "new bundle identifier",
        files="pbxproj",
    ),
]
RULES_BY_ID = {rule.id: rule for rule in RULES}
assert len(RULES_BY_ID) == len(RULES), "rule ids must be unique"


CATEGORY_LABELS = {
    "network": "network host or credentials sent somewhere new",
    "apple-events": "app scripted through Apple Events",
    "url-scheme": "URL scheme invoked with user data",
    "credentials": "Keychain, secret or connection use",
    "permission": "new permission",
    "destructive": "destructive action",
    "other-app-storage": "reading another app's storage",
    "process": "process launch or dynamic code (reviewer's call)",
    "build": "build script, dependency or linker change (runs code in CI)",
    "identity": "bundle identity",
    "binary": "binary file",
    "entitlements": "entitlements",
}


# Bare domain strings must end in a country code or one of these: catalog IDs and SF Symbol names
# ("brew.actions", "plus.circle") look like domains too. Hosts in URLs are matched regardless.
GENERIC_TLDS = {
    "com", "net", "org", "io", "dev", "app", "ai", "xyz", "info", "biz", "cloud", "tech", "site",
    "online", "social", "network", "zone", "page", "link", "live", "news", "blog", "space", "store",
    "shop", "design", "tools", "software", "systems", "services", "email", "chat", "team", "work",
    "world", "today", "run", "one", "codes", "digital", "media", "studio", "host", "website", "pro",
    "edu", "gov", "mil", "int", "local", "internal", "lan", "home", "arpa", "onion", "wtf", "lol",
}


def _domain_is_plausible_host(domain: str) -> bool:
    labels = domain.split(".")
    if len(labels) < 2:
        return False
    if labels[-1] in FILE_LIKE_TLDS:
        return False
    if len(labels[-1]) != 2 and labels[-1] not in GENERIC_TLDS:
        return False
    # Reverse-DNS identifiers (com.brnbw.tuna, pl.maketheweb.cleanshotx) aren't hosts.
    if labels[0] in REVERSE_DNS_ROOTS and len(labels) >= 3:
        return False
    return True


def _rule_applies(rule: Rule, path: str) -> bool:
    name = os.path.basename(path)
    if rule.skip_files is not None and rule.skip_files.search(path):
        return False
    if rule.files == "plist":
        return name.endswith((".plist", ".entitlements"))
    if rule.files == "pbxproj":
        return name == "project.pbxproj"
    if rule.files == "xcscheme":
        return name.endswith(".xcscheme")
    if rule.files == "store":
        return name == "STORE.md"
    return not name.endswith(UNSCANNED_SUFFIXES)


def _scannable(path: str) -> bool:
    name = os.path.basename(path)
    return name == "STORE.md" or not name.endswith(UNSCANNED_SUFFIXES)


def tokens_in_line(rule: Rule, line: str) -> list[str]:
    if PLIST_BOILERPLATE.search(line):
        return []
    tokens = []
    for match in rule.pattern.finditer(line):
        if rule.token:
            tokens.append(rule.token)
            continue
        token = match.group(1) if match.groups() else match.group(0)
        token = token.strip()
        if not token:
            continue
        if rule.id == "network-origin":
            token = _origin(token)
        elif rule.id == "network-domain":
            if not _domain_is_plausible_host(token) or SYMBOL_CONTEXT.search(line):
                continue
        elif rule.id == "store-warning":
            tokens.extend(part.strip() for part in token.split(",") if part.strip())
            continue
        elif rule.id == "destructive-wording":
            token = token.lower()
        if rule.exclude is not None and rule.exclude.search(token):
            continue
        tokens.append(token)
    return tokens


def _origin(url: str) -> str:
    scheme, _, rest = url.partition("://")
    host = re.split(r"[/?#]", rest, maxsplit=1)[0]
    if "\\(" not in host:
        host = host.lower()
    return scheme.lower() + "://" + host


def count_tokens(files: dict[str, str]) -> dict[str, collections.Counter]:
    """Occurrences of every rule's tokens across files, keyed by rule id."""
    counts: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for path, text in files.items():
        if not _scannable(path):
            continue
        rules = [rule for rule in RULES if _rule_applies(rule, path)]
        for line in text.splitlines():
            for rule in rules:
                for token in tokens_in_line(rule, line):
                    counts[rule.id][token] += 1
    return counts


# --------------------------------------------------------------------------------------------
# Git plumbing
# --------------------------------------------------------------------------------------------


class GitError(RuntimeError):
    pass


def git(repo: str, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", repo, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if check and result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode("utf-8", errors="replace")


def rev_parse(repo: str, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip()


def merge_base(repo: str, base: str, head: str) -> str:
    out = git(repo, "merge-base", base, head, check=False).strip()
    if not out:
        raise GitError(f"{base} and {head} have no common history")
    return out


def tree_files(repo: str, rev: str, prefixes: list[str]) -> dict[str, str]:
    """Text of every scannable file under the prefixes at rev."""
    if not prefixes:
        return {}
    listing = git(repo, "ls-tree", "-r", "-z", rev, "--", *prefixes)
    entries = []
    for record in listing.split("\0"):
        if not record:
            continue
        meta, _, path = record.partition("\t")
        _mode, kind, sha = meta.split()
        if kind == "blob" and _scannable(path):
            entries.append((path, sha))
    if not entries:
        return {}
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "--batch"],
        input="".join(f"{sha}\n" for _, sha in entries).encode(),
        stdout=subprocess.PIPE,
        check=True,
    )
    data = proc.stdout
    files: dict[str, str] = {}
    offset = 0
    for path, _sha in entries:
        header_end = data.index(b"\n", offset)
        size = int(data[offset:header_end].split()[2])
        body = data[header_end + 1 : header_end + 1 + size]
        offset = header_end + 1 + size + 1
        if b"\0" in body[:8000]:
            continue
        files[path] = body.decode("utf-8", errors="replace")
    return files


def top_level_extension_dirs(repo: str, rev: str) -> set[str]:
    """Top-level folders that hold an Xcode project: one extension each."""
    dirs = set()
    for path in git(repo, "ls-tree", "-r", "-d", "--name-only", rev).splitlines():
        parts = path.split("/")
        if len(parts) == 2 and parts[1].endswith(".xcodeproj"):
            dirs.add(parts[0])
    return dirs


def read_file(repo: str, rev: str, path: str) -> "str | None":
    result = subprocess.run(
        ["git", "-C", repo, "show", f"{rev}:{path}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------------------------
# Extensions and ownership
# --------------------------------------------------------------------------------------------


@dataclasses.dataclass
class Extension:
    dir: str
    bundle_id: "str | None" = None
    version: "str | None" = None

    @property
    def media_keys(self) -> set[str]:
        """Names the uploader may look up the extension's media by (see upload-extension.sh)."""
        bare = self.dir[: -len("Extension")] if self.dir.endswith("Extension") else self.dir
        # The policy's slug (P12): HueExtension → hue, OpenTerminalHereExtension → open-terminal-here.
        policy_slug = slugify(re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", bare))
        keys = {self.dir, bare, slugify(self.dir), slugify(bare), bare.lower(), policy_slug}
        if self.bundle_id:
            keys |= {self.bundle_id, self.bundle_id.rsplit(".", 1)[-1]}
        return {key for key in keys if key}


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def read_extension(repo: str, rev: str, directory: str) -> Extension:
    extension = Extension(directory)
    projects = [
        p for p in git(repo, "ls-tree", "-d", "--name-only", rev, f"{directory}/").splitlines()
        if p.endswith(".xcodeproj")
    ]
    pbxproj = read_file(repo, rev, f"{projects[0]}/project.pbxproj") if projects else None
    if pbxproj:
        ids = [
            value for value in re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*\"?([^\";]+)\"?;", pbxproj)
            if "test" not in value.lower()
        ]
        extension.bundle_id = ids[0] if ids else None
    plist = read_file(repo, rev, f"{directory}/Info.plist")
    if plist:
        match = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>", plist)
        version = match.group(1).strip() if match else None
        if version and version.startswith("$(") and pbxproj:
            marketing = re.search(r"MARKETING_VERSION\s*=\s*\"?([^\";]+)\"?;", pbxproj)
            version = marketing.group(1) if marketing else None
        extension.version = version
    return extension


MEDIA_SCREENSHOT = re.compile(r"^media/screenshots/([^/]+)(?:/|\.[A-Za-z0-9]+$)")
MEDIA_ICON = re.compile(r"^media/icons/([^/]+)\.[A-Za-z0-9]+$")


def path_owner(path: str, extensions: "Iterable[Extension]") -> "str | None":
    """The extension folder that owns path, or None when the path is shared.

    An extension owns its folder and its own store media. Media whose key matches no extension, or
    more than one, is shared."""
    extensions = list(extensions)
    for extension in extensions:
        if path.startswith(extension.dir + "/"):
            return extension.dir
    match = MEDIA_SCREENSHOT.match(path) or MEDIA_ICON.match(path)
    if match:
        key = match.group(1)
        owners = [e.dir for e in extensions if key in e.media_keys]
        if len(owners) == 1:
            return owners[0]
    return None


@dataclasses.dataclass
class Change:
    status: str
    path: str
    old_path: "str | None" = None
    binary: bool = False


def changed_files(repo: str, base: str, head: str) -> list[Change]:
    raw = git(repo, "diff", "--no-renames", "--name-status", "-z", base, head)
    parts = [p for p in raw.split("\0") if p]
    changes = []
    for status, path in zip(parts[0::2], parts[1::2]):
        changes.append(Change(status[0], path))
    numstat = git(repo, "diff", "--no-renames", "--numstat", "-z", base, head)
    binary = set()
    for record in numstat.split("\0"):
        fields = record.split("\t")
        if len(fields) == 3 and fields[0] == "-" and fields[1] == "-":
            binary.add(fields[2])
    for change in changes:
        change.binary = change.path in binary
    return changes


def added_lines(repo: str, base: str, head: str, prefixes: list[str]) -> list[tuple[str, int, str]]:
    """(path, line number, text) for every line added between base and head under prefixes."""
    if not prefixes:
        return []
    diff = git(repo, "diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", base, head, "--", *prefixes)
    lines = []
    path = None
    number = 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            number = int(match.group(1)) if match else 0
        elif line.startswith("+") and path is not None:
            lines.append((path, number, line[1:]))
            number += 1
    return lines


# --------------------------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------------------------


def content_hits(
    base_files: dict[str, str], head_files: dict[str, str], additions: list[tuple[str, int, str]]
) -> list[dict]:
    """Rule hits: tokens HEAD has that the base lacks (`new`) or has fewer of (`more`)."""
    base_counts = count_tokens(base_files)
    head_counts = count_tokens(head_files)
    hits = []
    for rule_id, counter in head_counts.items():
        rule = RULES_BY_ID[rule_id]
        for token, count in sorted(counter.items()):
            before = base_counts.get(rule_id, collections.Counter()).get(token, 0)
            if (rule.mode == "new" and before) or count <= before:
                continue
            evidence = [
                {"path": path, "line": number, "text": text.strip()[:240]}
                for path, number, text in additions
                if _rule_applies(rule, path) and token in tokens_in_line(rule, text)
            ][:5]
            hits.append({
                "rule": rule.id,
                "category": rule.category,
                "token": token,
                "message": rule.message,
                "base_count": before,
                "head_count": count,
                "evidence": evidence,
            })
    hits.sort(key=lambda h: (h["category"], h["rule"], h["token"]))
    return hits


def classify(repo: str, base: str, head: str, only: "Iterable[str] | None" = None) -> dict:
    """The JSON report for base...head (see module docstring). `only` limits the per-extension
    reports to those extension folders; shared changes are always reported."""
    repo = git(repo, "rev-parse", "--show-toplevel").strip()
    head_sha = rev_parse(repo, head)
    base_sha = rev_parse(repo, base)
    if not head_sha or not base_sha:
        raise GitError(f"unknown revision: {base if not base_sha else head}")
    effective_base = merge_base(repo, base_sha, head_sha)

    base_dirs = top_level_extension_dirs(repo, effective_base)
    head_dirs = top_level_extension_dirs(repo, head_sha)
    extensions = {}
    for directory in sorted(base_dirs | head_dirs):
        rev = head_sha if directory in head_dirs else effective_base
        extensions[directory] = read_extension(repo, rev, directory)

    changes = changed_files(repo, effective_base, head_sha)
    shared = []
    touched: dict[str, list[Change]] = collections.defaultdict(list)
    for change in changes:
        owner = path_owner(change.path, extensions.values())
        if owner is None:
            shared.append({"path": change.path, "status": change.status, "reason": _shared_reason(change.path)})
        else:
            touched[owner].append(change)

    reports = []
    for directory, extension_changes in sorted(touched.items()):
        if only is not None and directory not in only:
            continue
        extension = extensions[directory]
        if directory not in base_dirs:
            kind = "admission"
        elif directory not in head_dirs:
            kind = "removal"
        else:
            kind = "update"
        media = sorted(c.path for c in extension_changes if not c.path.startswith(directory + "/"))
        prefixes = [directory]
        hits = content_hits(
            tree_files(repo, effective_base, prefixes),
            tree_files(repo, head_sha, prefixes),
            added_lines(repo, effective_base, head_sha, prefixes),
        )
        for change in extension_changes:
            name = os.path.basename(change.path)
            if change.path.endswith(".entitlements"):
                hits.append(_path_hit("entitlements", "entitlements", change, "entitlements file changed"))
            elif change.binary and not name.lower().endswith(IMAGE_SUFFIXES):
                hits.append(_path_hit("binary", "binary", change, "binary file added or changed"))
        reports.append({
            "dir": directory,
            "bundle_id": extension.bundle_id,
            "kind": kind,
            "version_base": read_extension(repo, effective_base, directory).version
            if directory in base_dirs else None,
            "version_head": extension.version if directory in head_dirs else None,
            "files": sorted(c.path for c in extension_changes if c.path.startswith(directory + "/")),
            "media": media,
            "hits": hits,
            "clean_update": kind == "update" and not hits,
        })

    return {
        "schema_version": SCHEMA_VERSION,
        "base": base_sha,
        "head": head_sha,
        "merge_base": effective_base,
        "extensions": reports,
        "shared": shared,
        "summary": {
            "extensions": len(reports),
            "admissions": [r["dir"] for r in reports if r["kind"] == "admission"],
            "clean_updates": [r["dir"] for r in reports if r["clean_update"]],
            "risky": [r["dir"] for r in reports if r["hits"] or r["kind"] != "update"],
            "shared_changes": len(shared),
        },
    }


def _path_hit(rule: str, category: str, change: Change, message: str) -> dict:
    return {
        "rule": rule,
        "category": category,
        "token": change.path,
        "message": message,
        "base_count": None,
        "head_count": None,
        "evidence": [{"path": change.path, "line": None, "text": f"{change.status} {change.path}"}],
    }


def _shared_reason(path: str) -> str:
    if path.startswith("media/"):
        return "store media that belongs to no single extension"
    if path.startswith((".github/", "scripts/", "tests/", "Makefile")):
        return "shared tooling"
    if path.endswith(".xcworkspace") or ".xcworkspace/" in path:
        return "workspace"
    return "outside every extension folder"


# --------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------


def summary_text(report: dict) -> str:
    lines = [f"extension-risk {report['base'][:10]}...{report['head'][:10]} (merge base {report['merge_base'][:10]})"]
    if not report["extensions"] and not report["shared"]:
        lines.append("No changes.")
    for ext in report["extensions"]:
        version = ""
        if ext["version_base"] != ext["version_head"]:
            version = f" {ext['version_base'] or '–'} → {ext['version_head'] or '–'}"
        elif ext["version_head"]:
            version = f" {ext['version_head']} (unchanged)"
        verdict = "clean update" if ext["clean_update"] else ext["kind"]
        if ext["hits"]:
            verdict += f", {len(ext['hits'])} risk hit(s)"
        lines.append(f"\n{ext['dir']}{version}: {verdict}")
        if ext["media"]:
            lines.append(f"  own media: {len(ext['media'])} file(s)")
        for hit in ext["hits"]:
            counts = ""
            if hit["base_count"] is not None and hit["base_count"]:
                counts = f" ({hit['base_count']} → {hit['head_count']})"
            lines.append(f"  [{hit['category']}] {hit['message']}: {hit['token']}{counts}")
            for ev in hit["evidence"][:2]:
                where = f"{ev['path']}:{ev['line']}" if ev["line"] else ev["path"]
                lines.append(f"      {where}  {ev['text'][:120]}")
    if report["shared"]:
        lines.append(f"\nShared changes ({len(report['shared'])}): need the maintainer")
        for item in report["shared"]:
            lines.append(f"  {item['status']} {item['path']}  ({item['reason']})")
    return "\n".join(lines)


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        prog="extension-risk",
        description="Classify BASE...HEAD against the extension policy's risk list. "
        "Prints JSON on stdout and a readable summary on stderr.",
    )
    parser.add_argument("base")
    parser.add_argument("head", nargs="?", default="HEAD")
    parser.add_argument("--repo", default=os.getcwd(), help="repository (default: current directory)")
    parser.add_argument("--json-out", help="also write the JSON report to this file")
    parser.add_argument("--quiet", action="store_true", help="no summary on stderr")
    parser.add_argument("--summary", action="store_true", help="summary on stdout, no JSON")
    args = parser.parse_args(argv)

    try:
        report = classify(args.repo, args.base, args.head)
    except GitError as error:
        print(f"extension-risk: {error}", file=sys.stderr)
        return 2

    document = json.dumps(report, indent=2, sort_keys=True)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            fh.write(document + "\n")
    if args.summary:
        print(summary_text(report))
        return 0
    print(document)
    if not args.quiet:
        print(summary_text(report), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
