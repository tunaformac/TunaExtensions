import Foundation
import TunaKit
import XCTest

@testable import FancyTextExtension

final class FancyTextExtensionTests: XCTestCase {
  @MainActor
  func testActionReturnsEveryProductionStyleAsSearchableText() async throws {
    let catalog = FancyTextActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.fancy-text.actions", name: "Actions")
    )
    let action = try XCTUnwrap(catalog.actions.first)

    let result = await action.callback(TextSnippetItem(text: "Tuna 42!"), nil)
    guard case .results(let results) = result else {
      return XCTFail("Expected listed results")
    }

    XCTAssertEqual(results.count, 49)
    let first = try XCTUnwrap(results.first as? FancyTextItem)
    XCTAssertEqual(first.title, "𝚃𝚞𝚗𝚊 42!")
    XCTAssertEqual(first.textValue, first.title)
    XCTAssertEqual(first.detail, "Monospace")
    XCTAssertEqual(first.searchKeys, [first.title, "Monospace"])
    XCTAssertEqual(first.typeID, .textSnippet)
  }

  @MainActor
  func testActionOnlyAcceptsNonemptyText() throws {
    let catalog = FancyTextActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.fancy-text.actions", name: "Actions")
    )
    let action = try XCTUnwrap(catalog.actions.first)
    let predicateAction = try XCTUnwrap(action as? PredicateAwareAction)

    XCTAssertEqual(action.supportedSubjectTypes, [.textSnippet])
    XCTAssertTrue(try XCTUnwrap(predicateAction.subjectPredicate)(TextSnippetItem(text: "hello")))
    XCTAssertFalse(try XCTUnwrap(predicateAction.subjectPredicate)(TextSnippetItem(text: "")))
  }

  func testRepresentativeMappingsAndUnmappedCharacters() throws {
    let fonts = try FancyTextFont.productionFonts

    XCTAssertEqual(try font(named: "Full Width", in: fonts).convert("Az09 🙂"), "Ａｚ０９ 🙂")
    XCTAssertEqual(try font(named: "Double Underline", in: fonts).convert("Ab1"), "A̳b̳1̳")
    XCTAssertEqual(try font(named: "1337 [extreme]", in: fonts).convert("Tuna"), "7(_)/\\/@")
    XCTAssertFalse(fonts.contains { $0.name == "Comic" })
  }

  @MainActor
  func testExtensionDeclarationIsValid() throws {
    let extensionInstance = try FancyTextExtension(bundle: Bundle(for: FancyTextExtension.self))
    let declaration = try XCTUnwrap(extensionInstance.declaration)

    try declaration.validate()
    let compatibility = try XCTUnwrap(declaration.compatibility)
    XCTAssertEqual(compatibility.minTuna, "0.94")
    XCTAssertEqual(compatibility.minTunaKit, "1.20.0")
  }

  private func font(named name: String, in fonts: [FancyTextFont]) throws -> FancyTextFont {
    try XCTUnwrap(fonts.first { $0.name == name })
  }
}
