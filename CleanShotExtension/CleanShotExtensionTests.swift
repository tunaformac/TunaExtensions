import Foundation
import TunaKit
import XCTest

@testable import TunaCleanShot

final class CleanShotExtensionTests: XCTestCase {
  @MainActor
  func testRecentCapturesIsABrowseEntry() async throws {
    let catalog = CleanShotCommandsCatalog(
      definition: CatalogDefinition(
        identifier: "cleanshot.commands",
        name: "CleanShot Commands",
        enabledByDefault: true,
        settings: []
      )
    )

    await catalog.scan()

    let item = try XCTUnwrap(catalog.objects.first)
    XCTAssertEqual(item.typeID, .searchCatalogEntry)
    XCTAssertTrue(item is CatalogHierarchyNode)
    let deferredItem = try XCTUnwrap(item as? DeferredBrowseCatalogItem)
    XCTAssertFalse(deferredItem.usesCatalogResultsPresentation)
    XCTAssertEqual(deferredItem.childResultsPresentation.gridConfiguration.columns, 4)
  }

  func testRecentCapturesReturnsNewestHundredByFileDateFromShallowMediaDirectories() throws {
    let fileManager = FileManager.default
    let mediaDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: mediaDirectory) }

    for index in 0..<120 {
      let date = Date(timeIntervalSince1970: TimeInterval(index))
      let captureDirectory = mediaDirectory
        .appendingPathComponent("media_\(index)", isDirectory: true)
      try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
      let captureURL = captureDirectory.appendingPathComponent("\(index).png")
      try Data().write(to: captureURL)
      try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: captureURL.path)
      let opposingDirectoryDate = Date(timeIntervalSince1970: TimeInterval(120 - index))
      try fileManager.setAttributes(
        [.modificationDate: opposingDirectoryDate],
        ofItemAtPath: captureDirectory.path
      )
    }

    let captures = try CleanShotMediaLibrary.recentCaptures(
      in: mediaDirectory,
      fileManager: fileManager
    )

    XCTAssertEqual(captures.count, CleanShotMediaLibrary.maximumCaptureCount)
    XCTAssertEqual(captures.first?.title, "119")
    XCTAssertEqual(captures.last?.title, "20")
    XCTAssertFalse(captures.contains { $0.title == "19" })
  }

  func testRecentCapturesDoesNotRecursivelyWalkCaptureDirectories() throws {
    let fileManager = FileManager.default
    let mediaDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nestedDirectory = mediaDirectory
      .appendingPathComponent("media_nested", isDirectory: true)
      .appendingPathComponent("deeper", isDirectory: true)
    try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: mediaDirectory) }
    try Data().write(to: nestedDirectory.appendingPathComponent("ignored.png"))

    XCTAssertTrue(
      try CleanShotMediaLibrary.recentCaptures(in: mediaDirectory, fileManager: fileManager).isEmpty
    )
  }

  func testMissingMediaDirectoryIsAnEmptyLibrary() throws {
    let missingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    XCTAssertTrue(try CleanShotMediaLibrary.recentCaptures(in: missingDirectory).isEmpty)
  }

  func testInvalidMediaDirectoryPropagatesTheReadError() throws {
    let mediaFile = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try Data().write(to: mediaFile)
    defer { try? FileManager.default.removeItem(at: mediaFile) }

    XCTAssertThrowsError(try CleanShotMediaLibrary.recentCaptures(in: mediaFile))
  }
}
