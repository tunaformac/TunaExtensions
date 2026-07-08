import Foundation
import TunaKit

public final class GitHubNotificationsCatalog: Catalog, GitHubDateSortedCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var unreadBranch = makeUnreadBranch()
  private lazy var allBranch = makeAllBranch()
  private lazy var rootItem = BrowseCatalogItem(
    title: "Notifications",
    id: "github.notifications",
    detail: "Browse unread or all notifications",
    catalogIcon: .init(symbolName: "bell", color: .purple)
  ) { [weak self] in
    self?.rootChildren() ?? []
  }

  public var objects: [CatalogItem] {
    [rootItem]
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    unreadBranch.reset()
    allBranch.reset()
    GitHubCatalogSupport.postScanFinished(identifier: identifier)
  }

  private func rootChildren() -> [CatalogItem] {
    [unreadBranch, allBranch]
  }

  private func makeUnreadBranch() -> DeferredBrowseCatalogItem {
    DeferredBrowseCatalogItem(
      title: "Unread",
      id: "github.notifications.unread",
      detail: "Unread notifications",
      catalogIcon: .init(symbolName: "circle.fill", color: .red),
      loadingItemProvider: { GitHubCatalogSupport.loadingMessageItem() },
      errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
      didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
    ) {
      try await Self.loadNotifications(includeRead: false)
    }
  }

  private func makeAllBranch() -> DeferredBrowseCatalogItem {
    DeferredBrowseCatalogItem(
      title: "All",
      id: "github.notifications.all",
      detail: "All notifications",
      catalogIcon: .init(symbolName: "tray.full", color: .indigo),
      loadingItemProvider: { GitHubCatalogSupport.loadingMessageItem() },
      errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
      didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
    ) {
      try await Self.loadNotifications(includeRead: true)
    }
  }

  nonisolated static func loadNotifications(includeRead: Bool) async throws -> [CatalogItem] {
    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      return [GitHubCatalogSupport.authRequiredMessageItem()]
    }

    let connectionNotifications = try await GitHubCatalogSupport.loadPerConnection(connections) {
      connection in
      let client = try GitHubAPIClient(connection: connection)
      return try await
        (includeRead ? client.fetchAllNotifications() : client.fetchUnreadNotifications())
    }
    let totalConnections = connections.count
    let emptyTitle = includeRead ? "No notifications" : "No unread notifications"
    let symbolName = includeRead ? "tray" : "bell.slash"

    if totalConnections == 1, let first = connectionNotifications.first {
      return makeNotificationChildren(
        first.payload,
        connection: first.connection,
        totalConnections: totalConnections,
        baseHierarchyIdentifier: includeRead
          ? "github.notifications.all" : "github.notifications.unread",
        emptyTitle: emptyTitle,
        emptySymbolName: symbolName
      )
    }

    let baseHierarchyIdentifier =
      includeRead ? "github.notifications.all" : "github.notifications.unread"
    return connectionNotifications.map { result in
      GitHubCatalogSupport.connectionSection(
        for: result.connection,
        id: "\(baseHierarchyIdentifier).connection.\(result.offset)",
        symbolName: "bell",
        children: makeNotificationChildren(
          result.payload,
          connection: result.connection,
          totalConnections: totalConnections,
          baseHierarchyIdentifier: "\(baseHierarchyIdentifier).\(result.offset)",
          emptyTitle: emptyTitle,
          emptySymbolName: symbolName
        ),
        sortOrder: result.offset
      )
    }
  }

  private nonisolated static func makeNotificationChildren(
    _ notifications: [GitHubNotification],
    connection: GitHubConnection,
    totalConnections: Int,
    baseHierarchyIdentifier: String,
    emptyTitle: String,
    emptySymbolName: String
  ) -> [CatalogItem] {
    let items = notifications.map {
      makeItem($0, connection: connection, totalConnections: totalConnections)
    }

    guard !items.isEmpty else {
      return [
        GitHubSectionItem(
          title: emptyTitle,
          id: "\(baseHierarchyIdentifier).empty",
          symbolName: emptySymbolName,
          children: []
        )
      ]
    }

    return items
  }

  private nonisolated static func makeItem(
    _ notification: GitHubNotification,
    connection: GitHubConnection,
    totalConnections: Int
  ) -> CatalogItem {
    let detail = GitHubCatalogSupport.connectionPrefixedDetail(
      "\(notification.repositoryFullName) · \(notification.reason)",
      for: connection,
      totalConnections: totalConnections
    )
    return GitHubResultItem(
      title: notification.title,
      detail: detail,
      url: notification.url,
      symbolName: symbol(for: notification.subjectType),
      capturedAt: notification.updatedAt
    )
  }

  private nonisolated static func symbol(for subjectType: String) -> String {
    switch subjectType.lowercased() {
    case "pullrequest":
      return "arrow.triangle.pull"
    case "issue":
      return "exclamationmark.circle"
    case "discussion":
      return "bubble.left"
    case "commit":
      return "chevron.left.slash.chevron.right"
    case "release":
      return "tag"
    default:
      return "bell"
    }
  }
}

public final class GitHubUnreadNotificationsCatalog: Catalog, GitHubDateSortedCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = DeferredBrowseCatalogItem(
    title: "Unread Notifications",
    id: "github.notifications.unread.direct",
    detail: "Browse unread GitHub notifications directly",
    catalogIcon: .init(symbolName: "circle.fill", color: .red),
    loadingItemProvider: { GitHubCatalogSupport.loadingMessageItem() },
    errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
    didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
  ) {
    try await GitHubNotificationsCatalog.loadNotifications(includeRead: false)
  }

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    rootItem.reset()
    GitHubCatalogSupport.postScanFinished(identifier: identifier)
  }
}

public final class GitHubAllNotificationsCatalog: Catalog, GitHubDateSortedCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = DeferredBrowseCatalogItem(
    title: "All Notifications",
    id: "github.notifications.all.direct",
    detail: "Browse all GitHub notifications directly",
    catalogIcon: .init(symbolName: "tray.full", color: .indigo),
    loadingItemProvider: { GitHubCatalogSupport.loadingMessageItem() },
    errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
    didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
  ) {
    try await GitHubNotificationsCatalog.loadNotifications(includeRead: true)
  }

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    rootItem.reset()
    GitHubCatalogSupport.postScanFinished(identifier: identifier)
  }
}
