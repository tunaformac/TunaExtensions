import Foundation
import TunaKit
import XCTest

@testable import TunaPoof

@MainActor
final class PoofExtensionTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testParserFindsArrayAndSingleSnippetsAndSkipsDisabledEntries() throws {
    try """
      [[snippets]]
      trigger = ":sig"
      replace = "Best regards,\\nMikkel{{cursor}}"
      description = "Signature"

      [[snippet]]
      trigger = ':off'
      replace = 'Hidden'
      disabled = true
      """.write(to: directory.appending(path: "group.toml"), atomically: true, encoding: .utf8)
    try """
      trigger = ":date"
      replace = "{{date}}"
      case_sensitive = false
      """.write(to: directory.appending(path: "single.toml"), atomically: true, encoding: .utf8)

    let records = PoofSnippetParser.activeRecords(in: directory)

    XCTAssertEqual(Set(records.map(\.trigger)), [":sig", ":date"])
    let signature = try XCTUnwrap(records.first(where: { $0.trigger == ":sig" }))
    XCTAssertEqual(signature.replacementTemplate, "Best regards,\nMikkel{{cursor}}")
    XCTAssertEqual(signature.details, "Signature")
    XCTAssertEqual(records.first(where: { $0.trigger == ":date" })?.caseSensitive, false)
  }

  func testParserSupportsMultilineStrings() throws {
    let file = PoofSnippetParser.parse(
      #"""
      [[snippets]]
      trigger = ":multi"
      replace = """
      line one
      line two
      """
      """#,
      sourceURL: directory.appending(path: "multi.toml")
    )

    XCTAssertEqual(file.entries.first?.record.replacementTemplate, "line one\nline two\n")
  }

  func testCreateAndDeleteRoundTripWithoutRewritingNeighbor() throws {
    let neighbor = """
      [[snippets]]
      trigger = ":keep"
      replace = "Keep me"
      """
    try neighbor.write(
      to: directory.appending(path: "neighbor.toml"), atomically: true, encoding: .utf8)
    let store = PoofSnippetStore(directory: directory)

    let created = try store.create(trigger: ":hello", replacement: "Hello\nworld")
    let loaded = try XCTUnwrap(
      PoofSnippetParser.activeRecords(in: directory).first(where: { $0.trigger == ":hello" }))
    XCTAssertEqual(loaded.replacementTemplate, "Hello\nworld")

    try store.delete(created)

    XCTAssertEqual(PoofSnippetParser.activeRecords(in: directory).map(\.trigger), [":keep"])
    XCTAssertEqual(
      try String(contentsOf: directory.appending(path: "neighbor.toml"), encoding: .utf8),
      neighbor
    )
  }

  func testDeletingOnlyActiveSnippetPreservesDisabledNeighbor() throws {
    let url = directory.appending(path: "group.toml")
    try """
      [[snippets]]
      trigger = ":active"
      replace = "Active"

      [[snippets]]
      trigger = ":disabled"
      replace = "Disabled"
      disabled = true
      """.write(to: url, atomically: true, encoding: .utf8)
    let active = try XCTUnwrap(PoofSnippetParser.activeRecords(in: directory).first)

    try PoofSnippetStore(directory: directory).delete(active)

    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(try String(contentsOf: url).contains("trigger = \":disabled\""))
  }

  func testDuplicateTriggerIsRejected() throws {
    let store = PoofSnippetStore(directory: directory)
    _ = try store.create(trigger: ":same", replacement: "One")

    XCTAssertThrowsError(try store.create(trigger: ":same", replacement: "Two")) { error in
      XCTAssertEqual(error.localizedDescription, "A Poof snippet already uses the trigger :same.")
    }
  }

  func testRendererMatchesPoofTokensAndRemovesCursorMarker() {
    let date = Date(timeIntervalSince1970: 0)
    let template = "At {{date:yyyy}} {{clipboard}} {{uuid}} {{cursor}}done"
    let rendered = PoofSnippetRenderer.render(
      template, now: date, clipboard: "copied", uuid: "fixed-id")

    XCTAssertEqual(rendered, "At 1970 copied fixed-id done")
  }

  func testSnippetSearchIncludesDescriptionTriggerAndContent() {
    let record = PoofSnippetRecord(
      trigger: ":sig", replacementTemplate: "Best regards", details: "Work signature",
      caseSensitive: true, sourceURL: directory.appending(path: "sig.toml"), sourceIndex: 0)
    let item = PoofSnippetItem(record: record)

    XCTAssertEqual(item.title, "Work signature")
    XCTAssertTrue(item.searchText.contains(":sig"))
    XCTAssertTrue(item.searchText.contains("Best regards"))
    XCTAssertEqual(item.detail, ":sig  ·  Best regards")
  }

  func testCatalogExposesOptInSnippetsAndSeparateBrowsableRoot() async throws {
    try """
      trigger = ":sig"
      replace = "Best regards"
      description = "Signature"
      """.write(to: directory.appending(path: "sig.toml"), atomically: true, encoding: .utf8)
    let snippetsCatalog = PoofCatalog(
      identifier: "poof.snippets",
      configDirectory: directory
    )
    let browseCatalog = PoofBrowseCatalog(
      identifier: "poof.snippets.search",
      configDirectory: directory
    )

    await snippetsCatalog.scan()
    await browseCatalog.scan()

    XCTAssertEqual(snippetsCatalog.objects.map(\.title), ["Signature"])
    let root = try XCTUnwrap(browseCatalog.objects.only as? PoofLibraryItem)
    XCTAssertEqual(root.hierarchyChildren().map(\.title), ["Signature"])
    let preview = root.preview(maxDimension: 64)
    XCTAssertNotNil(preview.image)
    XCTAssertNil(preview.systemSymbolName)
  }

  func testDeclarationMakesSnippetsCompatibleWithTextActions() throws {
    let extensionInstance = try PoofExtension(bundle: Bundle(for: PoofExtension.self))
    let declaration = try XCTUnwrap(extensionInstance.declaration)
    try declaration.validate()

    let registration = try XCTUnwrap(declaration.typeRegistrations.first(where: {
      $0.typeID == .poofSnippet
    }))
    XCTAssertEqual(registration.inheritsFrom, [.textSnippet])
    let enrichment = try XCTUnwrap(declaration.appBrowseEnrichments.only)
    XCTAssertEqual(enrichment.bundleIdentifiers, ["com.brnbw.Poof"])
    XCTAssertEqual(enrichment.entries.only?.catalogIdentifier, "poof.snippets.search")
    XCTAssertEqual(
      Set(declaration.catalogs.map(\.id)),
      ["poof.snippets", "poof.snippets.search"]
    )
  }

  func testActionsUseTargetsAndEllipsesConsistently() {
    let catalog = PoofActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "poof.actions", name: "Poof Actions")
    )

    XCTAssertEqual(Set(catalog.actions.map(\.id)), [
      "create-snippet", "delete-snippet", "edit-snippet", "open-library",
    ])
    let create = catalog.actions.first(where: { $0.id == "create-snippet" })
    XCTAssertEqual(create?.title, "Create Snippet")
    XCTAssertEqual(create?.supportedSubjectTypes, [.textSnippet])
    XCTAssertEqual(create?.targetRequirement, CatalogActionTargetRequirement.none)
    XCTAssertTrue(catalog.actions.allSatisfy {
      !$0.title.hasSuffix("…") || $0.targetRequirement != .none
    })
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
