import AppKit
import Foundation
import TunaKit

struct GitHubConnection: Sendable {
  let record: ExtensionConnectionRecord
  let accessToken: String

  var displayName: String {
    record.trimmedDisplayName
  }
}

enum GitHubCatalogSupport {
  static let providerIdentifier = "github"

  static let connectionDefinition = ExtensionConnectionDefinition(
    providerIdentifier: providerIdentifier,
    providerName: "GitHub",
    kind: .secret,
    supportsBaseURL: true,
    defaultBaseURL: "https://github.com",
    baseURLLabel: "GitHub URL",
    secretLabel: "Personal Access Token",
    description:
      "Classic personal access token with scopes: repo, read:org, read:user, notifications. Leave the URL at https://github.com for public GitHub, or point it at your GitHub Enterprise server.",
    connectButtonLabel: "Add Connection"
  )

  static func connections(for type: AnyClass) -> [GitHubConnection] {
    guard let bundleIdentifier = Bundle(for: type).bundleIdentifier else { return [] }
    let store = ExtensionConnectionStore(
      extensionIdentifier: bundleIdentifier,
      providerIdentifier: providerIdentifier
    )
    return store.orderedRecords().compactMap { record in
      guard
        let accessToken = store.accessToken(for: record)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !accessToken.isEmpty
      else { return nil }
      return GitHubConnection(record: record, accessToken: accessToken)
    }
  }

  static func authRequiredMessageItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Connect GitHub",
      message: "Add at least one GitHub connection in extension settings to load this catalog.",
      symbolName: "person.crop.circle.badge.exclamationmark",
      tintColor: .systemOrange
    )
  }

  static func loadingItem() -> CatalogLoadingItem {
    CatalogLoadingItem(
      title: "Loading GitHub",
      message: "Fetching GitHub items for this catalog."
    )
  }

  static func messageItem(for error: Error) -> CatalogMessageItem {
    if let error = error as? GitHubAPIError {
      return CatalogMessageItem(
        title: error.title,
        message: error.localizedDescription,
        symbolName: "exclamationmark.triangle",
        tintColor: .systemOrange
      )
    }

    return CatalogMessageItem(
      title: "GitHub request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func relativeDateString(from date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  static func repositoryDetail(_ repository: GitHubRepository, includeStarCount: Bool = false)
    -> String
  {
    var parts: [String] = [repository.fullName]
    if repository.isPrivate {
      parts.append("Private")
    }
    if includeStarCount {
      parts.append("★\(repository.stargazersCount)")
    }
    if let starred = relativeDateString(from: repository.starredAt) {
      parts.append("Starred \(starred)")
    } else if let updated = relativeDateString(from: repository.updatedAt) {
      parts.append("Updated \(updated)")
    }
    return parts.joined(separator: " · ")
  }

  static func loadPerConnection<Payload: Sendable>(
    _ connections: [GitHubConnection],
    operation: @escaping @Sendable (GitHubConnection) async throws -> Payload
  ) async throws -> [(offset: Int, connection: GitHubConnection, payload: Payload)] {
    try await withThrowingTaskGroup(
      of: (offset: Int, connection: GitHubConnection, payload: Payload).self
    ) { group in
      for (offset, connection) in connections.enumerated() {
        group.addTask {
          (offset, connection, try await operation(connection))
        }
      }

      var results: [(offset: Int, connection: GitHubConnection, payload: Payload)] = []
      for try await result in group {
        results.append(result)
      }
      return results.sorted { $0.offset < $1.offset }
    }
  }

  static func connectionPrefixedDetail(
    _ detail: String,
    for connection: GitHubConnection,
    totalConnections: Int
  ) -> String {
    guard totalConnections > 1 else { return detail }
    return "\(connection.displayName) · \(detail)"
  }

  static func connectionSection(
    for connection: GitHubConnection,
    id: String,
    symbolName: String,
    children: [CatalogItem],
    sortOrder: Int = .max
  ) -> CatalogItem {
    GitHubSectionItem(
      title: connection.displayName,
      id: id,
      symbolName: symbolName,
      children: children,
      sortOrder: sortOrder
    )
  }

  static let sortOptions: [CatalogSortOption] = [
    capturedAtDescendingSort,
    capturedAtAscendingSort,
    .nameAscending,
    .nameDescending,
  ]

  static var defaultSortOptionID: String {
    CatalogSortOption.capturedAtDescending.id
  }

  // Identifier-based shim: didLoad closures capture only the identifier, so
  // they can't call the instance-side Catalog.reportScanFinished().
  static func postScanFinished(identifier: String) {
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  static func flattenedIssueLikeItems(
    from connectionSections: [(
      offset: Int, connection: GitHubConnection, payload: [GitHubSection<GitHubIssueOrPullRequest>]
    )],
    totalConnections: Int,
    makeItem: (GitHubIssueOrPullRequest, GitHubConnection, Int) -> CatalogItem
  ) -> [CatalogItem] {
    connectionSections.flatMap { result in
      result.payload.flatMap(\.items).map {
        (item: $0, connection: result.connection, offset: result.offset)
      }
    }
    .sorted { lhs, rhs in
      let lhsDate = lhs.item.updatedAt ?? .distantPast
      let rhsDate = rhs.item.updatedAt ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhs.offset < rhs.offset
    }
    .map {
      makeItem($0.item, $0.connection, totalConnections)
    }
  }

  static func scan(
    for catalogType: AnyClass,
    identifier: String,
    messageStore: LockedValue<[CatalogItem]?>,
    onMissingConnections: () -> Void = {},
    onError: () -> Void = {},
    work: ([GitHubConnection]) async throws -> Void
  ) async {
    let connections = connections(for: catalogType)
    guard !connections.isEmpty else {
      messageStore.value = [authRequiredMessageItem()]
      onMissingConnections()
      postScanFinished(identifier: identifier)
      return
    }

    do {
      try await work(connections)
      messageStore.value = nil
    } catch {
      onError()
      messageStore.value = [messageItem(for: error)]
    }

    postScanFinished(identifier: identifier)
  }

  private static let capturedAtDescendingSort = CatalogSortOption(
    id: CatalogSortOption.capturedAtDescending.id,
    title: CatalogSortOption.capturedAtDescending.title,
    detail: CatalogSortOption.capturedAtDescending.detail
  ) { lhs, rhs in
    compareByDate(lhs, rhs, ascending: false)
  }

  private static let capturedAtAscendingSort = CatalogSortOption(
    id: CatalogSortOption.capturedAtAscending.id,
    title: CatalogSortOption.capturedAtAscending.title,
    detail: CatalogSortOption.capturedAtAscending.detail
  ) { lhs, rhs in
    compareByDate(lhs, rhs, ascending: true)
  }

  private static func compareByDate(_ lhs: CatalogItem, _ rhs: CatalogItem, ascending: Bool) -> Bool
  {
    if let lhsSection = lhs as? GitHubSectionItem, let rhsSection = rhs as? GitHubSectionItem,
      lhsSection.sortOrder != rhsSection.sortOrder
    {
      return lhsSection.sortOrder < rhsSection.sortOrder
    }

    let lhsDate = (lhs as? TimestampedCatalogItem)?.capturedAtDate
    let rhsDate = (rhs as? TimestampedCatalogItem)?.capturedAtDate
    switch (lhsDate, rhsDate) {
    case (let l?, let r?) where l != r:
      return ascending ? (l < r) : (l > r)
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }
}

final class GitHubSectionItem: CatalogEntity, CatalogHierarchyNode, TimestampedCatalogItem,
  @unchecked Sendable
{
  private let children: [CatalogItem]
  private let symbolName: String
  private let iconColor: CatalogIconColor
  let sortOrder: Int
  let capturedAtDate: Date

  init(
    title: String,
    id: String,
    symbolName: String,
    iconColor: CatalogIconColor = .gray,
    children: [CatalogItem],
    sortOrder: Int = .max
  ) {
    self.symbolName = symbolName
    self.iconColor = iconColor
    self.children = children
    self.sortOrder = sortOrder
    let normalizedSortOrder = max(0, min(sortOrder, 10_000))
    self.capturedAtDate = Date.distantFuture.addingTimeInterval(-Double(normalizedSortOrder))
    super.init(id: id, title: title, path: nil)
    typeID = .searchCatalogEntry
  }

  func hierarchyChildren() -> [CatalogItem] {
    children
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.catalogIcon(
      symbolName: symbolName,
      color: iconColor,
      maxDimension: maxDimension
    )
  }
}

final class GitHubResultItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  @unchecked Sendable
{
  private let detailText: String
  private let symbolName: String
  let capturedAtDate: Date

  var textValue: String { path ?? title }

  init(title: String, detail: String, url: URL, symbolName: String, capturedAt: Date? = nil) {
    self.detailText = detail
    self.symbolName = symbolName
    self.capturedAtDate = capturedAt ?? .distantPast
    super.init(id: url.absoluteString, title: title, path: url.absoluteString)
    typeID = .url
  }

  override var detail: String? {
    detailText
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol(symbolName)
  }
}

@MainActor
public protocol GitHubDateSortedCatalog: CatalogSortingProviding {}

@MainActor
extension GitHubDateSortedCatalog {
  public var sortOptions: [CatalogSortOption] {
    GitHubCatalogSupport.sortOptions
  }

  public var defaultSortOptionID: String {
    GitHubCatalogSupport.defaultSortOptionID
  }
}
