import AppKit
import Foundation
import TunaKit
import XCTest

@testable import TunaStrongbox

private let work = "11111111-1111-1111-1111-111111111111"
private let personal = "22222222-2222-2222-2222-222222222222"

final class StrongboxExtensionTests: XCTestCase {
  @MainActor
  func testDeclarationIndexesOnlyTheSearchRoots() throws {
    let instance = try StrongboxExtension(bundle: Bundle(for: StrongboxExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    let compatibility = try XCTUnwrap(declaration.compatibility)
    XCTAssertEqual(compatibility.minTuna, "0.110")
    XCTAssertEqual(compatibility.minTunaKit, "1.22.0")
    XCTAssertEqual(declaration.catalogs.map(\.id), ["strongbox.search"])
    XCTAssertEqual(declaration.catalogs.first?.presentation, .source)
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["strongbox.actions"])
    XCTAssertEqual(declaration.typeRegistrations.map(\.typeID), [.strongboxEntry, .strongboxQuery])
    XCTAssertTrue(declaration.typeRegistrations.allSatisfy { $0.inheritsFrom.isEmpty })
    XCTAssertEqual(
      declaration.defaultActionRankings.map { $0.actions.map(\.actionID) },
      [["copy"], ["find-and-copy"]])
    XCTAssertTrue(declaration.appBrowseEnrichments.isEmpty)
  }

  @MainActor
  func testCatalogOffersTwoScopedSearchRoots() {
    let catalog = StrongboxCatalog(
      definition: CatalogDefinition(
        identifier: "strongbox.search", name: "Strongbox", enabledByDefault: true, settings: []))
    XCTAssertEqual(catalog.objects.map(\.id), ["strongbox.search.root", "strongbox.otp.root"])
    XCTAssertTrue(catalog.objects.allSatisfy { $0 is ScopedSearchBrowseCatalogItem })
  }

  @MainActor
  func testActionsAcceptOnlyTheirOwnSubjectsAndNeedNoTarget() {
    let catalog = StrongboxActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "strongbox.actions", name: "Strongbox Actions"))
    XCTAssertEqual(catalog.actions.map(\.id), ["copy", "find-and-copy"])
    XCTAssertEqual(catalog.actions.map(\.supportedSubjectTypes), [[.strongboxEntry], [.strongboxQuery]])
    XCTAssertTrue(catalog.actions.allSatisfy { $0.targetRequirement == .none })
    XCTAssertTrue(catalog.actions.allSatisfy { !$0.recordsCommandHistory })
  }

  @MainActor
  func testShortQueriesContactNothingAndLongQueriesOfferEveryField() async {
    let short = await StrongboxRuntime.queryItems(" g ", first: .totp)
    XCTAssertEqual(short.count, 1)
    XCTAssertFalse(short.first is StrongboxQueryItem)

    let items = await StrongboxRuntime.queryItems("github", first: .totp)
    XCTAssertEqual(items.compactMap { ($0 as? StrongboxQueryItem)?.field }, [.totp, .password, .username])
  }

  // MARK: Clipboard

  @MainActor
  func testCopiesAreMarkedAndClearedWhenTunaQuits() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("strongbox-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(ConcealedClipboard(pasteboard: pasteboard).write("secret", clearAfter: 60))
    let types = pasteboard.types ?? []
    XCTAssertTrue(ConcealedClipboard.markers.allSatisfy(types.contains))
    XCTAssertEqual(pasteboard.string(forType: .string), "secret")

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    XCTAssertNil(pasteboard.string(forType: .string))
  }

  @MainActor
  func testQuittingLeavesANewerCopyAlone() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("strongbox-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(ConcealedClipboard(pasteboard: pasteboard).write("secret", clearAfter: 60))
    pasteboard.clearContents()
    pasteboard.setString("newer", forType: .string)

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    XCTAssertEqual(pasteboard.string(forType: .string), "newer")
  }

  // MARK: Vault selection

  func testOnlyVaultIsUsedWithoutAChoice() throws {
    XCTAssertEqual(StrongboxDatabase.selectedForSearch(try databases(personal), preferredID: nil)?.id, personal)
  }

  func testSeveralVaultsNeedAChoice() throws {
    XCTAssertNil(StrongboxDatabase.selectedForSearch(try databases(work, personal), preferredID: nil))
  }

  func testRememberedVaultIsUsed() throws {
    let selected = StrongboxDatabase.selectedForSearch(
      try databases(work, personal), preferredID: personal.lowercased())
    XCTAssertEqual(selected?.id, personal)
  }

  func testMissingRememberedVaultNeedsANewChoice() throws {
    XCTAssertNil(StrongboxDatabase.selectedForSearch(try databases(personal), preferredID: work))
    XCTAssertNil(StrongboxDatabase.selectedForSearch(try databases(personal), preferredID: "not-a-uuid"))
  }

  // MARK: Direct match

  func testOnlyExactTitleIsCopied() throws {
    let match = StrongboxEntry.directMatch(in: try entries(["GitHub", "GitHub Enterprise"]), query: " github ")
    XCTAssertEqual(match?.title, "GitHub")
  }

  func testOnlyResultIsCopied() throws {
    XCTAssertEqual(
      StrongboxEntry.directMatch(in: try entries(["GitHub Enterprise"]), query: "git")?.title,
      "GitHub Enterprise")
  }

  func testDuplicateTitlesAreListed() throws {
    XCTAssertNil(StrongboxEntry.directMatch(in: try entries(["GitHub", "GitHub"]), query: "GitHub"))
  }

  func testSeveralPartialMatchesAreListed() throws {
    XCTAssertNil(StrongboxEntry.directMatch(in: try entries(["GitHub", "GitLab"]), query: "git"))
  }

  func testFullListIsNeverTrusted() throws {
    let titles = ["GitHub"] + (1..<StrongboxClient.searchLimit).map { "GitHub \($0)" }
    XCTAssertNil(StrongboxEntry.directMatch(in: try entries(titles), query: "GitHub"))
  }

  // MARK: Reveal parsing

  func testKnownRevealLayoutsAreRead() throws {
    let layouts = [
      #"{"fields":{"password":"secret"}}"#,
      #"{"revealed_credential":{"fields":{"password":"secret"}}}"#,
      #"{"password":"secret"}"#,
      #"{"fields":{"password":{"value":"secret"}}}"#,
      #"{"fields":[{"name":"password","value":"secret"}]}"#,
    ]
    for layout in layouts {
      XCTAssertEqual(try json(layout).revealedValue("password"), "secret", layout)
    }
  }

  func testUnknownRevealLayoutReadsNothing() throws {
    XCTAssertNil(try json(#"{"data":{"password":"secret"}}"#).revealedValue("password"))
  }

  func testUnavailableFieldIsReported() throws {
    XCTAssertTrue(try json(#"{"revealed_credential":{"unavailable_fields":["totp"]}}"#).listsUnavailable("totp"))
  }

  func testShapeHidesValuesAndUnknownKeys() throws {
    let shape = try json(#"{"fields":{"custom:Bank PIN 1234":"secret","password":"hunter2"},"data":"x"}"#).shape
    XCTAssertEqual(shape, "{fields:{password:string,1 other},1 other}")
    for leaked in ["secret", "hunter2", "Bank", "1234", "data"] {
      XCTAssertFalse(shape.contains(leaked), leaked)
    }
  }

  // MARK: Fixtures

  private func databases(_ ids: String...) throws -> [StrongboxDatabase] {
    try ids.map { id in
      try JSONDecoder().decode(
        StrongboxDatabase.self,
        from: Data(#"{"database_id":"\#(id)","database_name":"Vault","locked":true}"#.utf8))
    }
  }

  private func entries(_ titles: [String]) throws -> [StrongboxEntry] {
    try titles.map { title in
      try JSONDecoder().decode(
        StrongboxEntry.self,
        from: Data(
          #"{"credential_id":"\#(UUID().uuidString)","database_id":"\#(work)","database_name":"Work","title":"\#(title)"}"#
            .utf8))
    }
  }

  private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}

/// Runs the real client against a scripted stand-in for `strongbox-mcp`, for the failures real
/// Strongbox can't be made to produce on demand. Only tests start an unverified helper.
final class StrongboxProtocolTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testCopiesTheRevealedPassword() async throws {
    let client = try fakeClient([:])
    let entry = try await onlyEntry(client)
    let value = try await client.value(of: .password, in: entry)
    XCTAssertEqual(value, "secret-value")
    XCTAssertEqual(calls(), ["initialize", "notifications/initialized", "list_databases", "find_credentials", "reveal_credential"])
  }

  func testLockedVaultIsUnlockedOnceAndTheSearchRetried() async throws {
    let client = try fakeClient(["locked": true])
    _ = try await onlyEntry(client)
    XCTAssertEqual(calls().filter { $0 != "initialize" && $0 != "notifications/initialized" },
                   ["list_databases", "find_credentials", "unlock_database", "find_credentials"])
  }

  func testStrongboxRefusalsMapToTheirMessages() async throws {
    let cases: [(String, StrongboxError)] = [
      ("This MCP host is not paired with Strongbox.", .notPaired),
      ("Strongbox MCP access is disabled.", .disabled),
      ("The user declined.", .denied),
    ]
    for (text, expected) in cases {
      let client = try fakeClient(["reveal_credential": "error:" + text])
      let entry = try await onlyEntry(client)
      await assertThrows(expected) { _ = try await client.value(of: .password, in: entry) }
    }
  }

  func testAnotherProtocolVersionIsRefused() async throws {
    let client = try fakeClient(["protocolVersion": "2024-11-05"])
    await assertThrows(.invalidResponse) { _ = try await client.databases() }
  }

  func testMalformedAndOversizedResponsesAreRefused() async throws {
    for behaviour in ["garbage", "huge"] {
      let client = try fakeClient(["list_databases": behaviour])
      await assertThrows(.invalidResponse) { _ = try await client.databases() }
    }
  }

  func testMatchesFromAnotherVaultAreRefused() async throws {
    let client = try fakeClient(["matchDatabase": "33333333-3333-3333-3333-333333333333"])
    let database = try await client.databases()[0]
    await assertThrows(.invalidResponse) { _ = try await client.search("Sample", databaseID: database.id) }
  }

  func testDisconnectIsReportedAndTheNextRequestReconnects() async throws {
    let client = try fakeClient(["reveal_credential": "exit"])
    let entry = try await onlyEntry(client)
    await assertThrows(.disconnected) { _ = try await client.value(of: .password, in: entry) }
    _ = try await client.databases()
    XCTAssertEqual(calls().filter { $0 == "initialize" }.count, 2)
  }

  func testAResultArrivingAfterCancellationIsDropped() async throws {
    let client = try fakeClient(["reveal_credential": ["delay": 1.0]])
    let entry = try await onlyEntry(client)
    let request = Task { try await client.value(of: .password, in: entry) }
    try await Task.sleep(for: .milliseconds(200))
    request.cancel()
    do {
      _ = try await request.value
      XCTFail("A cancelled request returned its value.")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
  }

  // MARK: Fake helper

  private func fakeClient(_ configuration: [String: Any]) throws -> StrongboxClient {
    var configuration = configuration
    configuration["log"] = directory.appendingPathComponent("calls.log").path
    let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
    let script = directory.appendingPathComponent("strongbox-mcp-\(UUID().uuidString)")
    try Self.fakeHelper.replacingOccurrences(of: "CONFIGURATION", with: json)
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("calls.log"))
    return StrongboxClient { try MCPConnection(helper: HelperProcess(executable: script)) }
  }

  private func onlyEntry(_ client: StrongboxClient) async throws -> StrongboxEntry {
    let database = try await client.databases()[0]
    let entries = try await client.search("Sample", databaseID: database.id)
    return try XCTUnwrap(entries.first)
  }

  private func calls() -> [String] {
    let log = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    return log.split(separator: "\n").map(String.init)
  }

  private func assertThrows(
    _ expected: StrongboxError, file: StaticString = #filePath, line: UInt = #line,
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? StrongboxError, expected, file: file, line: line)
    }
  }

  private static let fakeHelper = #"""
    #!/usr/bin/env python3
    import json, sys, time
    CONFIG = json.loads(r'''CONFIGURATION''')
    VAULT = "11111111-1111-1111-1111-111111111111"
    ENTRY = {"credential_id": "44444444-4444-4444-4444-444444444444",
             "database_id": CONFIG.get("matchDatabase", VAULT), "database_name": "Dummy",
             "title": "Sample", "username": "user", "available_fields": ["password", "totp"]}
    unlocked = False

    def tool_result(value): return {"structuredContent": value}
    def tool_error(text): return {"isError": True, "content": [{"type": "text", "text": text}]}

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        name = message.get("params", {}).get("name", method) if method == "tools/call" else method
        with open(CONFIG["log"], "a") as log: log.write(name + "\n")
        if "id" not in message: continue
        behaviour = CONFIG.get(name, "ok")
        if behaviour == "exit": sys.exit(0)
        if behaviour in ("garbage", "huge"):
            sys.stdout.write(("not json" if behaviour == "garbage" else "x" * (9 * 1024 * 1024)) + "\n")
            sys.stdout.flush()
            continue
        if isinstance(behaviour, dict): time.sleep(behaviour.get("delay", 0))
        if isinstance(behaviour, str) and behaviour.startswith("error:"): result = tool_error(behaviour[6:])
        elif method == "initialize": result = {"protocolVersion": CONFIG.get("protocolVersion", "2025-06-18")}
        elif name == "list_databases": result = tool_result({"databases": [{"database_id": VAULT, "database_name": "Dummy", "locked": True}]})
        elif name == "unlock_database": unlocked = True; result = tool_result({"unlocked": True})
        elif name == "find_credentials" and CONFIG.get("locked") and not unlocked:
            result = tool_error("The database is locked. Call unlock_database first.")
        elif name == "find_credentials": result = tool_result({"matches": [ENTRY]})
        else: result = tool_result({"revealed_credential": {"fields": {"password": "secret-value"}}})
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
        sys.stdout.flush()
    """#
}
