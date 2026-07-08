import Foundation
import TunaKit

private let gitHubPullRequestSectionOrderByTitle: [String: Int] = [
  "Open": 0,
  "Assigned": 1,
  "Mentioned": 2,
  "Review Requests": 3,
  "Reviewed": 4,
  "Recently Closed": 5,
]

public final class GitHubPullRequestsCatalog: Catalog, GitHubDateSortedCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Pull Requests",
    id: "github.pull-requests",
    detail: "Open, assigned, mentioned, review requests, reviewed, and recently closed",
    catalogIcon: .init(symbolName: "arrow.triangle.pull", color: .green),
    loadingItemProvider: { GitHubCatalogSupport.loadingMessageItem() },
    errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
    didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) },
    loadChildren: {
      try await Self.loadBrowseChildren()
    },
    searchHandler: { query in
      try await Self.searchPullRequests(query: query)
    }
  )

  public var objects: [CatalogItem] {
    [rootItem]
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    rootItem.reset()
    GitHubCatalogSupport.postScanFinished(identifier: identifier)
  }

  private nonisolated static func loadBrowseChildren() async throws -> [CatalogItem] {
    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      return [GitHubCatalogSupport.authRequiredMessageItem()]
    }

    let connectionSections = try await GitHubCatalogSupport.loadPerConnection(connections) {
      connection in
      let client = try GitHubAPIClient(connection: connection)
      return try await client.fetchMyPullRequests()
    }
    let totalConnections = connections.count

    if totalConnections == 1, let first = connectionSections.first {
      return makeBrowseChildren(
        first.payload,
        connection: first.connection,
        totalConnections: totalConnections,
        baseHierarchyIdentifier: "github.pull-requests"
      )
    }

    return connectionSections.map { result in
      GitHubCatalogSupport.connectionSection(
        for: result.connection,
        id: "github.pull-requests.connection.\(result.offset)",
        symbolName: "arrow.triangle.pull",
        children: makeBrowseChildren(
          result.payload,
          connection: result.connection,
          totalConnections: totalConnections,
          baseHierarchyIdentifier: "github.pull-requests.\(result.offset)"
        ),
        sortOrder: result.offset
      )
    }
  }

  private nonisolated static func makeBrowseChildren(
    _ sections: [GitHubSection<GitHubIssueOrPullRequest>],
    connection: GitHubConnection,
    totalConnections: Int,
    baseHierarchyIdentifier: String
  ) -> [CatalogItem] {
    let children = sections.map { section in
      GitHubSectionItem(
        title: section.title,
        id:
          "\(baseHierarchyIdentifier).\(section.title.lowercased().replacingOccurrences(of: " ", with: "-"))",
        symbolName: "arrow.triangle.pull",
        children: section.items.map {
          makeItem($0, connection: connection, totalConnections: totalConnections)
        },
        sortOrder: gitHubPullRequestSectionOrderByTitle[section.title] ?? 999
      )
    }

    guard !children.isEmpty else {
      return [
        GitHubSectionItem(
          title: "No pull requests",
          id: "\(baseHierarchyIdentifier).empty",
          symbolName: "tray",
          children: [],
          sortOrder: 999
        )
      ]
    }

    return children
  }

  private nonisolated static func makeItem(
    _ item: GitHubIssueOrPullRequest,
    connection: GitHubConnection,
    totalConnections: Int
  ) -> CatalogItem {
    GitHubResultItem(
      title: item.title,
      detail: GitHubCatalogSupport.connectionPrefixedDetail(
        "\(item.repositoryFullName) · #\(item.number) · \(item.state)",
        for: connection,
        totalConnections: totalConnections
      ),
      url: item.url,
      symbolName: "arrow.triangle.pull",
      capturedAt: item.updatedAt
    )
  }

  private nonisolated static func searchPullRequests(query: String) async throws -> [CatalogItem] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      return try await loadRootSearchResults()
    }

    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      throw GitHubAPIError.missingConnection
    }

    let totalConnections = connections.count
    var items: [CatalogItem] = []
    for connection in connections {
      let client = try GitHubAPIClient(connection: connection)
      let results = try await client.searchPullRequests(query: normalized)
      items.append(
        contentsOf: results.map {
          makeItem($0, connection: connection, totalConnections: totalConnections)
        }
      )
    }
    return items
  }

  private nonisolated static func loadRootSearchResults() async throws -> [CatalogItem] {
    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      return [GitHubCatalogSupport.authRequiredMessageItem()]
    }

    let connectionSections = try await GitHubCatalogSupport.loadPerConnection(connections) {
      connection in
      let client = try GitHubAPIClient(connection: connection)
      return try await client.fetchMyPullRequests()
    }
    return GitHubCatalogSupport.flattenedIssueLikeItems(
      from: connectionSections,
      totalConnections: connections.count,
      makeItem: makeItem
    )
  }
}
