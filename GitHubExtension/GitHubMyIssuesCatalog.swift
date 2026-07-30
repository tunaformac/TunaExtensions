import Foundation
import TunaKit

private let gitHubIssueSectionOrderByTitle: [String: Int] = [
  "Created": 0,
  "Assigned": 1,
  "Mentioned": 2,
  "Recently Closed": 3,
]

public final class GitHubIssuesCatalog: Catalog, GitHubDateSortedCatalog, StartupScanningCatalog {
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Issues",
    id: "github.issues",
    detail: "Created, assigned, mentioned, and recently closed issues",
    catalogIcon: .init(symbolName: "exclamationmark.circle", color: .orange),
    loadingItemProvider: { GitHubCatalogSupport.loadingItem() },
    errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
    didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) },
    loadChildren: {
      try await Self.loadBrowseChildren()
    },
    searchHandler: { query in
      try await Self.searchIssues(query: query)
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
      return try await client.fetchMyIssues()
    }
    let totalConnections = connections.count

    if totalConnections == 1, let first = connectionSections.first {
      return makeBrowseChildren(
        first.payload,
        connection: first.connection,
        totalConnections: totalConnections,
        baseHierarchyIdentifier: "github.issues"
      )
    }

    return connectionSections.map { result in
      GitHubCatalogSupport.connectionSection(
        for: result.connection,
        id: "github.issues.connection.\(result.offset)",
        symbolName: "exclamationmark.circle",
        children: makeBrowseChildren(
          result.payload,
          connection: result.connection,
          totalConnections: totalConnections,
          baseHierarchyIdentifier: "github.issues.\(result.offset)"
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
        symbolName: "exclamationmark.circle",
        children: section.items.map {
          makeIssueItem($0, connection: connection, totalConnections: totalConnections)
        },
        sortOrder: gitHubIssueSectionOrderByTitle[section.title] ?? 999
      )
    }

    guard !children.isEmpty else {
      return [
        GitHubSectionItem(
          title: "No issues",
          id: "\(baseHierarchyIdentifier).empty",
          symbolName: "tray",
          children: [],
          sortOrder: 999
        )
      ]
    }

    return children
  }

  private nonisolated static func makeIssueItem(
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
      symbolName: "exclamationmark.circle",
      capturedAt: item.updatedAt
    )
  }

  private nonisolated static func searchIssues(query: String) async throws -> [CatalogItem] {
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
      let results = try await client.searchIssues(query: normalized)
      items.append(
        contentsOf: results.map {
          makeIssueItem($0, connection: connection, totalConnections: totalConnections)
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
      return try await client.fetchMyIssues()
    }
    return GitHubCatalogSupport.flattenedIssueLikeItems(
      from: connectionSections,
      totalConnections: connections.count,
      makeItem: makeIssueItem
    )
  }
}

public final class GitHubRepositoriesCatalog: Catalog, GitHubDateSortedCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var mineBranch = makeMineBranch()
  private lazy var starredBranch = makeStarredBranch()
  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Repositories",
    id: "github.repositories",
    detail: "Browse yours, browse starred, or search repositories",
    catalogIcon: .init(symbolName: "folder", color: .blue),
    childrenProvider: { [weak self] in
      self?.rootChildren() ?? []
    },
    searchHandler: { query in
      try await Self.searchRepositories(query: query)
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
    mineBranch.reset()
    starredBranch.reset()
    GitHubCatalogSupport.postScanFinished(identifier: identifier)
  }

  private func rootChildren() -> [CatalogItem] {
    [mineBranch, starredBranch]
  }

  private func makeMineBranch() -> DeferredBrowseCatalogItem {
    DeferredBrowseCatalogItem(
      title: "Mine",
      id: "github.repositories.mine",
      detail: "Your repositories sorted by recently updated",
      catalogIcon: .init(symbolName: "folder", color: .blue),
      loadingItemProvider: { GitHubCatalogSupport.loadingItem() },
      errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
      didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
    ) {
      try await Self.loadRepositories(
        baseHierarchyIdentifier: "github.repositories.mine",
        symbolName: "folder",
        includeStarCount: false,
        emptyTitle: "No repositories",
        fetch: { client in
          try await client.fetchMyRepositories()
        }
      )
    }
  }

  private func makeStarredBranch() -> DeferredBrowseCatalogItem {
    DeferredBrowseCatalogItem(
      title: "Starred",
      id: "github.repositories.starred",
      detail: "Repositories starred by you, newest stars first",
      catalogIcon: .init(symbolName: "star", color: .yellow),
      loadingItemProvider: { GitHubCatalogSupport.loadingItem() },
      errorItemProvider: { GitHubCatalogSupport.messageItem(for: $0) },
      didLoad: { [identifier] in GitHubCatalogSupport.postScanFinished(identifier: identifier) }
    ) {
      try await Self.loadRepositories(
        baseHierarchyIdentifier: "github.repositories.starred",
        symbolName: "star",
        includeStarCount: true,
        emptyTitle: "No starred repositories",
        fetch: { client in
          try await client.fetchStarredRepositories()
        }
      )
    }
  }

  private nonisolated static func loadRepositories(
    baseHierarchyIdentifier: String,
    symbolName: String,
    includeStarCount: Bool,
    emptyTitle: String,
    fetch: @escaping @Sendable (GitHubAPIClient) async throws -> [GitHubRepository]
  ) async throws -> [CatalogItem] {
    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      return [GitHubCatalogSupport.authRequiredMessageItem()]
    }

    let connectionRepositories = try await GitHubCatalogSupport.loadPerConnection(connections) {
      connection in
      let client = try GitHubAPIClient(connection: connection)
      return try await fetch(client)
    }
    let totalConnections = connections.count

    if totalConnections == 1, let first = connectionRepositories.first {
      return makeRepositoryChildren(
        first.payload,
        connection: first.connection,
        totalConnections: totalConnections,
        baseHierarchyIdentifier: baseHierarchyIdentifier,
        symbolName: symbolName,
        includeStarCount: includeStarCount,
        emptyTitle: emptyTitle
      )
    }

    return connectionRepositories.map { result in
      GitHubCatalogSupport.connectionSection(
        for: result.connection,
        id: "\(baseHierarchyIdentifier).connection.\(result.offset)",
        symbolName: symbolName,
        children: makeRepositoryChildren(
          result.payload,
          connection: result.connection,
          totalConnections: totalConnections,
          baseHierarchyIdentifier: "\(baseHierarchyIdentifier).\(result.offset)",
          symbolName: symbolName,
          includeStarCount: includeStarCount,
          emptyTitle: emptyTitle
        ),
        sortOrder: result.offset
      )
    }
  }

  private nonisolated static func searchRepositories(query: String) async throws -> [CatalogItem] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let connections = GitHubCatalogSupport.connections(for: Self.self)
    guard !connections.isEmpty else {
      throw GitHubAPIError.missingConnection
    }

    let totalConnections = connections.count
    var items: [CatalogItem] = []
    for connection in connections {
      let client = try GitHubAPIClient(connection: connection)
      let results =
        normalized.isEmpty
        ? try await client.fetchMyRepositories()
        : try await client.searchRepositories(query: normalized)
      items.append(
        contentsOf: results.map { repository in
          GitHubRepositoryCatalogFormatter.makeItem(
            repository,
            connection: connection,
            totalConnections: totalConnections,
            symbolName: "folder",
            includeStarCount: false
          )
        }
      )
    }
    return items
  }
}

private enum GitHubRepositoryCatalogFormatter {
  static func makeItem(
    _ repository: GitHubRepository,
    connection: GitHubConnection,
    totalConnections: Int,
    symbolName: String,
    includeStarCount: Bool
  ) -> CatalogItem {
    let detail = GitHubCatalogSupport.repositoryDetail(
      repository,
      includeStarCount: includeStarCount
    )
    return GitHubResultItem(
      title: repository.fullName,
      detail: GitHubCatalogSupport.connectionPrefixedDetail(
        detail,
        for: connection,
        totalConnections: totalConnections
      ),
      url: repository.htmlURL,
      symbolName: symbolName,
      capturedAt: repository.sortDate
    )
  }
}

private func makeRepositoryChildren(
  _ repositories: [GitHubRepository],
  connection: GitHubConnection,
  totalConnections: Int,
  baseHierarchyIdentifier: String,
  symbolName: String,
  includeStarCount: Bool,
  emptyTitle: String
) -> [CatalogItem] {
  let children = repositories.map { repository in
    GitHubRepositoryCatalogFormatter.makeItem(
      repository,
      connection: connection,
      totalConnections: totalConnections,
      symbolName: symbolName,
      includeStarCount: includeStarCount
    )
  }

  guard !children.isEmpty else {
    return [
      GitHubSectionItem(
        title: emptyTitle,
        id: "\(baseHierarchyIdentifier).empty",
        symbolName: "tray",
        children: []
      )
    ]
  }

  return children
}
