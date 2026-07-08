import Foundation
import TunaKit

public final class SafariBookmarksCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .bookmarks, mode: .all)
  }
}

public final class SafariBookmarksSearchCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .bookmarks, mode: .search)
  }
}

public final class SafariReadingListCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .readingList, mode: .all)
  }
}

public final class SafariReadingListSearchCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .readingList, mode: .search)
  }
}

public final class SafariFavoritesCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .favorites, mode: .all)
  }
}

public final class SafariFavoritesSearchCatalog: SafariBookmarksCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .favorites, mode: .search)
  }
}

@MainActor
public class SafariBookmarksCatalogBase: NSObject, Catalog {
  enum Mode {
    case all
    case search
  }

  public let identifier: String
  public let name: String
  private let section: SafariBookmarksSection
  private let mode: Mode

  public var availabilityStatus: CatalogAvailabilityStatus = .normal
  private var provider: SafariBookmarksProvider = .shared

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let childrenStore = LockedValue<[CatalogItem]>([])
  private lazy var searchItem = BrowseCatalogItem(
    title: section.searchItemTitle,
    id: section.id,
    detail: section.searchItemDetail,
    catalogIcon: .init(symbolName: section.searchItemSymbolName, color: section.searchItemColor)
  ) { [weak self] in
    self?.childrenStore.readValue { $0 } ?? []
  }

  public var objects: [CatalogItem] {
    switch mode {
    case .all:
      return itemsStore.readValue { $0 }
    case .search:
      return [searchItem]
    }
  }

  fileprivate init(definition: CatalogDefinition, section: SafariBookmarksSection, mode: Mode) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.section = section
    self.mode = mode
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Safari catalog type instead.")
  }

  public func scan() async {
    let provider = UncheckedSendableBox(self.provider)
    let section = self.section

    struct ScanResult: Sendable {
      var availability: CatalogAvailabilityStatus
      var items: [CatalogItem]
    }

    let result = await Task.detached(priority: .utility) { [provider] in
      let response = provider.value.loadSnapshot()
      let items = SafariBookmarksCatalogBase.buildItems(
        from: response.snapshot.items(for: section))
      let availability = SafariBookmarksCatalogBase.availabilityStatus(
        for: response)
      return ScanResult(availability: availability, items: items)
    }.value

    availabilityStatus = result.availability
    switch mode {
    case .all:
      itemsStore.value = result.items
    case .search:
      childrenStore.value = result.items
    }

    reportScanFinished()
  }

  nonisolated private static func availabilityStatus(
    for response: SafariBookmarksProviderResult
  ) -> CatalogAvailabilityStatus {
    guard let failure = response.failure else { return .normal }
    if response.snapshot.isEmpty {
      return .disabled(failure.message)
    }
    return .degraded(failure.message)
  }

  nonisolated private static func buildItems(
    from records: [SafariBookmarkRecord]
  ) -> [CatalogItem] {
    guard !records.isEmpty else { return [] }
    return records.map { SafariBookmarkItem(record: $0) }
  }
}

private enum SafariBookmarksSection: Sendable {
  case bookmarks
  case readingList
  case favorites

  var title: String {
    switch self {
    case .bookmarks: return "Bookmarks"
    case .readingList: return "Reading List"
    case .favorites: return "Favorites"
    }
  }

  var allCatalogName: String {
    "All \(title)"
  }

  var searchItemTitle: String {
    title
  }

  var searchItemDetail: String {
    switch self {
    case .bookmarks:
      return "Browse Safari bookmarks"
    case .readingList:
      return "Browse Safari Reading List items"
    case .favorites:
      return "Browse Safari favorites"
    }
  }

  var id: String {
    switch self {
    case .bookmarks:
      return "safari.bookmarks"
    case .readingList:
      return "safari.reading-list"
    case .favorites:
      return "safari.favorites"
    }
  }

  var searchItemSymbolName: String {
    switch self {
    case .bookmarks: return "book"
    case .readingList: return "eyeglasses"
    case .favorites: return "star"
    }
  }

  var searchItemColor: CatalogIconColor {
    switch self {
    case .bookmarks: return .blue
    case .readingList: return .teal
    case .favorites: return .yellow
    }
  }
}

private struct SafariBookmarksProviderResult: Sendable {
  var snapshot: SafariBookmarksSnapshot
  var failure: SafariBookmarksFailure?
}

private struct SafariBookmarksFailure: Sendable {
  var message: String
}

private final class SafariBookmarksProvider: @unchecked Sendable {
  static let shared = SafariBookmarksProvider()

  var bookmarksURLProvider: @Sendable () -> URL? = { defaultBookmarksURL() }
  var store: SafariBookmarksStore = .shared

  func loadSnapshot() -> SafariBookmarksProviderResult {
    guard let bookmarksURL = bookmarksURLProvider() else {
      return SafariBookmarksProviderResult(
        snapshot: .empty,
        failure: SafariBookmarksFailure(message: "Safari bookmarks file not found"))
    }

    return store.loadSnapshot(from: bookmarksURL)
  }

  private static func defaultBookmarksURL() -> URL? {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Safari", isDirectory: true)
      .appendingPathComponent("Bookmarks.plist")
  }
}

private final class SafariBookmarksStore: @unchecked Sendable {
  static let shared = SafariBookmarksStore()

  private struct State {
    var lastModified: Date?
    var snapshot: SafariBookmarksSnapshot
  }

  private let state = LockedValue(State(lastModified: nil, snapshot: .empty))

  func loadSnapshot(from fileURL: URL) -> SafariBookmarksProviderResult {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return SafariBookmarksProviderResult(
        snapshot: .empty,
        failure: SafariBookmarksFailure(message: "Safari bookmarks file not found"))
    }

    let lastModified =
      (try? fileManager.attributesOfItem(atPath: fileURL.path))?[
        .modificationDate] as? Date

    let cached = state.readValue { $0 }
    if let lastModified, let cachedModified = cached.lastModified, lastModified == cachedModified {
      return SafariBookmarksProviderResult(snapshot: cached.snapshot, failure: nil)
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let snapshot = try SafariBookmarksParser.parse(data: data)
      state.value = State(lastModified: lastModified, snapshot: snapshot)
      return SafariBookmarksProviderResult(snapshot: snapshot, failure: nil)
    } catch {
      let message = "Failed to load Safari bookmarks"
      if !cached.snapshot.isEmpty {
        return SafariBookmarksProviderResult(
          snapshot: cached.snapshot,
          failure: SafariBookmarksFailure(message: message))
      }
      return SafariBookmarksProviderResult(
        snapshot: .empty,
        failure: SafariBookmarksFailure(message: message))
    }
  }
}

private struct SafariBookmarksSnapshot: Sendable {
  var bookmarks: [SafariBookmarkRecord]
  var readingList: [SafariBookmarkRecord]
  var favorites: [SafariBookmarkRecord]

  static let empty = SafariBookmarksSnapshot(bookmarks: [], readingList: [], favorites: [])

  var isEmpty: Bool {
    bookmarks.isEmpty && readingList.isEmpty && favorites.isEmpty
  }

  func items(for section: SafariBookmarksSection) -> [SafariBookmarkRecord] {
    switch section {
    case .bookmarks: return bookmarks
    case .readingList: return readingList
    case .favorites: return favorites
    }
  }
}

private struct SafariBookmarkRecord: Sendable {
  var title: String
  var url: URL
  var folderPath: String
}

private final class SafariBookmarkItem: CatalogEntity, @unchecked Sendable {
  private let urlString: String
  private let folderPath: String

  init(record: SafariBookmarkRecord) {
    self.urlString = record.url.absoluteString
    self.folderPath = record.folderPath
    super.init(id: record.url.absoluteString, title: record.title, path: record.url.absoluteString)
    typeID = .url
  }

  override var searchText: String {
    var keys: [String] = [title, urlString]
    if !folderPath.isEmpty {
      keys.append(folderPath)
    }
    return keys.joined(separator: " ")
  }
}

private enum SafariBookmarksParser {
  static func parse(data: Data) throws -> SafariBookmarksSnapshot {
    let plist = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil)
    guard let root = plist as? [String: Any] else {
      throw SafariBookmarksParserError.invalidFormat
    }

    var snapshot = SafariBookmarksSnapshot.empty
    let children = root["Children"] as? [Any] ?? []

    for child in children {
      guard let node = child as? [String: Any] else { continue }
      guard let section = sectionForRoot(node) else { continue }
      walk(node, section: section, path: [], isRoot: true, snapshot: &snapshot)
    }

    return snapshot
  }

  private static func sectionForRoot(_ node: [String: Any]) -> SafariBookmarksSection? {
    guard let type = node["WebBookmarkType"] as? String else { return nil }
    if type == "WebBookmarkTypeProxy" { return nil }

    let title = node["Title"] as? String
    if let title, readingListRootIdentifiers.contains(title) {
      return .readingList
    }
    if let title, favoritesRootIdentifiers.contains(title) {
      return .favorites
    }

    return .bookmarks
  }

  private static func walk(
    _ node: [String: Any],
    section: SafariBookmarksSection,
    path: [String],
    isRoot: Bool,
    snapshot: inout SafariBookmarksSnapshot
  ) {
    let type = node["WebBookmarkType"] as? String

    if type == "WebBookmarkTypeList" || node["Children"] != nil {
      var nextPath = path
      if let title = node["Title"] as? String,
        let component = displayPathComponent(for: title, section: section, isRoot: isRoot)
      {
        nextPath.append(component)
      }

      let children = node["Children"] as? [Any] ?? []
      for child in children {
        guard let childNode = child as? [String: Any] else { continue }
        walk(childNode, section: section, path: nextPath, isRoot: false, snapshot: &snapshot)
      }
      return
    }

    guard type == "WebBookmarkTypeLeaf" else { return }
    guard let urlString = node["URLString"] as? String,
      let url = URL(string: urlString)
    else { return }

    let title = resolvedTitle(for: node, url: url)
    let folderPath = path.joined(separator: " / ")
    let record = SafariBookmarkRecord(title: title, url: url, folderPath: folderPath)

    switch section {
    case .bookmarks:
      snapshot.bookmarks.append(record)
    case .readingList:
      snapshot.readingList.append(record)
    case .favorites:
      snapshot.favorites.append(record)
    }
  }

  private static func resolvedTitle(for node: [String: Any], url: URL) -> String {
    if let uri = node["URIDictionary"] as? [String: Any],
      let title = uri["title"] as? String,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return title
    }

    if let title = node["Title"] as? String,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return title
    }

    return url.absoluteString
  }

  private static func displayPathComponent(
    for title: String?,
    section: SafariBookmarksSection,
    isRoot: Bool
  ) -> String? {
    guard let title, !title.isEmpty else { return nil }
    guard isRoot else { return title }

    switch title {
    case "BookmarksBar":
      return section == .favorites ? "Favorites" : "Bookmarks Bar"
    case "BookmarksMenu":
      return "Bookmarks Menu"
    case "com.apple.ReadingList":
      return "Reading List"
    default:
      return title
    }
  }

  private static let readingListRootIdentifiers: Set<String> = [
    "com.apple.ReadingList",
    "Reading List",
    "ReadingList",
  ]

  private static let favoritesRootIdentifiers: Set<String> = [
    "BookmarksBar",
    "Favorites",
  ]
}

private enum SafariBookmarksParserError: Error {
  case invalidFormat
}
