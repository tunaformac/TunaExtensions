import AppKit
import Foundation
import TunaKit

public final class SafariMetaCatalog: Catalog {
  public let identifier: String
  public let name: String

  private let objectsStore = LockedValue<[CatalogItem]>([])

  public var objects: [CatalogItem] {
    objectsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    struct ScanResult: Sendable {
      var items: [CatalogItem]
    }

    let result = await Task.detached(priority: .utility) {
      var items: [CatalogItem] = []
      if let pageInfo = SafariAppleScript.currentPageInfo() {
        let currentPage = SafariCurrentPageItem(lastKnownURL: pageInfo.url, title: pageInfo.title)
        items.append(currentPage)
      }

      items.append(contentsOf: SafariMetaCatalog.commandItems())

      items.append(SafariLastDownloadItem())

      return ScanResult(items: items)
    }.value

    objectsStore.value = result.items
    reportScanFinished()
  }

  nonisolated private static func commandItems() -> [CatalogItem] {
    let newTab = CommandItem(
      id: "new-tab",
      title: "New Tab",
      symbol: "plus.square.on.square",
      detail: "Open a new Safari tab"
    ) {
      SafariAppleScript.openNewTab()
    }

    let newPrivateWindow = CommandItem(
      id: "new-private-window",
      title: "New Private Window",
      symbol: "lock.window",
      detail: "Open a new private window"
    ) {
      SafariAppleScript.openNewPrivateWindow()
    }

    return [newTab, newPrivateWindow]
  }
}

private enum LatestDownloadResolver {
  static func resolve() -> URL? {
    guard
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      let enumerator = FileManager.default.enumerator(
        at: downloads,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    else { return nil }

    return enumerator.compactMap(candidate).max { $0.date < $1.date }?.url
  }

  private static let resourceKeys: [URLResourceKey] = [
    .isRegularFileKey,
    .isDirectoryKey,
    .isPackageKey,
    .isHiddenKey,
    .addedToDirectoryDateKey,
    .creationDateKey,
    .contentModificationDateKey,
  ]

  private static func candidate(_ value: Any) -> (url: URL, date: Date)? {
    guard let url = value as? URL else { return nil }
    guard !url.lastPathComponent.hasSuffix(".download") else { return nil }
    guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
    guard values.isHidden != true else { return nil }
    guard values.isRegularFile == true || values.isDirectory == true || values.isPackage == true
    else { return nil }

    let date = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate
    return date.map { (url.standardizedFileURL, $0) }
  }
}

private final class SafariCurrentPageItem: CatalogEntity, @unchecked Sendable {
  private let pageTitle: String?
  private let lastKnownURL: URL?

  init(lastKnownURL: URL?, title: String?) {
    self.pageTitle = title
    self.lastKnownURL = lastKnownURL
    super.init(
      id: SafariAppleScript.currentPageToken,
      title: "Current Page",
      path: SafariAppleScript.currentPageToken)
    typeID = .url
  }

  override var detail: String? {
    pageTitle ?? lastKnownURL?.absoluteString
  }

  override var searchText: String {
    var keys: [String] = [title]
    if let pageTitle {
      keys.append(pageTitle)
    }
    if let lastKnownURL {
      keys.append(lastKnownURL.absoluteString)
    }
    return keys.joined(separator: " ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("safari", tintColor: .systemBlue)
  }
}

private final class SafariLastDownloadItem: CatalogItem, ActionSubjectResolving,
  RequiresResolvedActionSubjects, @unchecked Sendable
{
  init() {
    super.init(id: "Last Download", title: "Last Download", type: .entity)
    typeID = .file
  }

  @MainActor
  func resolvedActionSubjects() -> [CatalogItem] {
    guard let url = LatestDownloadResolver.resolve() else { return [] }
    return [SafariDownloadedFileItem(fileURL: url)]
  }

  override var detail: String? {
    "Latest item in Downloads"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("arrow.down.circle", tintColor: .systemBlue)
  }
}

private final class SafariDownloadedFileItem: CatalogEntity, @unchecked Sendable {
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
    super.init(id: fileURL.path, title: fileURL.lastPathComponent, path: fileURL.path)
    typeID = fileTypeID(for: fileURL)
  }

  override var detail: String? {
    fileURL.deletingLastPathComponent().path
  }
}

private func fileTypeID(for url: URL) -> TypeID {
  let standardized = url.standardizedFileURL
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
    return .file
  }
  if isDirectory.boolValue {
    if standardized.pathExtension.lowercased() == "app" {
      return .application
    }
    return .directory
  }
  return .file
}
