import AppKit
import TunaKit
import XCTest

@testable import TunaSafari

final class SafariCurrentPageRuntimeResolutionTests: XCTestCase {
  override func tearDown() {
    SafariAppleScript.runOverride = nil
    SafariAppleScript.isSafariRunningOverride = nil
    super.tearDown()
  }

  func testCopyURLResolvesFrontmostSafariTabAtExecutionTime() async throws {
    SafariAppleScript.isSafariRunningOverride = { true }
    SafariAppleScript.runOverride = { _ in
      "Example Title__TUNA__SEPARATOR__https://example.com/path"
    }

    let action: CatalogAction? = await MainActor.run {
      let definition = ActionCatalogDefinition(
        identifier: "safari.actions",
        name: "Safari Actions"
      )
      let catalog = SafariActionsCatalog(definition: definition)
      return catalog.actions.first(where: { $0.title == "Copy URL" })
    }

    guard let action else {
      XCTFail("Missing Copy URL action")
      return
    }

    let currentPage = CatalogEntity(
      id: SafariAppleScript.currentPageToken, title: "Current Page",
      path: SafariAppleScript.currentPageToken)
    currentPage.typeID = .url

    let result = await action.callback(currentPage, nil)

    guard case .background(let task) = result else {
      XCTFail("Expected Shelf task to avoid blocking main thread")
      return
    }

    _ = await task.work()

    let value = await MainActor.run {
      NSPasteboard.general.string(forType: .string)
    }
    XCTAssertEqual(value, "https://example.com/path")
  }

  @MainActor
  func testLastDownloadOffersResolveAndCompatibleFileActions() async throws {
    SafariAppleScript.isSafariRunningOverride = { false }
    let ext = try SafariExtension(bundle: Bundle(for: SafariExtension.self))
    let registration = try XCTUnwrap(
      ext.typeRegistrations.first { $0.typeID == .safariLastDownload })
    XCTAssertEqual(registration.inheritsFrom, [.file])

    let catalog = SafariMetaCatalog(
      definition: CatalogDefinition(
        identifier: "safari.utilities", name: "Safari Utilities",
        enabledByDefault: true, settings: []))
    await catalog.scan()
    let lastDownload = try XCTUnwrap(catalog.objects.first { $0.id == "Last Download" })
    XCTAssertEqual(lastDownload.typeID, .safariLastDownload)
    TypeRegistry.shared.register(registration.typeID, inheritsFrom: registration.inheritsFrom)
    XCTAssertTrue(lastDownload is ActionSubjectResolving)

    let resolve = CatalogAction(id: "resolve", title: "Resolve") { _, _ in .success }
    resolve.supportedSubjectTypes = [.entity]
    let quickAction = CatalogAction(id: "perform-quick-action", title: "Perform Quick Action…") {
      _, _ in .success
    }
    quickAction.supportedSubjectTypes = [.file]
    let matches = SearchResultFiltering.filterActions(
      [resolve, quickAction].map {
        ScoreResult(
          object: $0, score: 1, ranges: [],
          sourceCatalogIdentifier: $0.id == "resolve" ? "tuna.common-actions" : "automation.actions")
      },
      selectedSubject: lastDownload, resolvedSubjects: [])
    XCTAssertEqual(Set(matches.map(\.object.id)), ["resolve", "perform-quick-action"])
  }
}
