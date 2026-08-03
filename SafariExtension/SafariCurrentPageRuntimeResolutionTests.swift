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
}
