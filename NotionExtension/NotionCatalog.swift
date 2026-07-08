import Foundation
import TunaKit

public final class NotionCatalog: Catalog, RescanSchedulingCatalog, StartupScanningCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?

  private let childrenStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let deferredLoadState = DeferredCatalogLoadState()

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Notion",
    id: "notion",
    detail: "Recently edited shared pages and data sources",
    catalogIcon: .init(symbolName: "book.pages", color: .gray),
    configuration: ScopedSearchConfiguration(debounce: .milliseconds(300), searchOnChange: true),
    childrenProvider: { [weak self] in
      self?.browseChildren() ?? []
    },
    searchHandler: { query in
      try await Self.search(query: query)
    }
  )

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    return [rootItem]
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func releaseRetainedState() {
    childrenStore.value = []
    messageStore.value = nil
    deferredLoadState.reset()
  }

  public func scan() async {
    defer { deferredLoadState.markLoadCompleted() }
    await NotionCatalogSupport.scan(
      for: NotionCatalog.self,
      identifier: identifier,
      messageStore: messageStore,
      onMissingConnections: { childrenStore.value = [] },
      onError: { childrenStore.value = [] }
    ) { connections in
      let items = try await Self.loadRecentItems(connections: connections)
      childrenStore.value = items.isEmpty ? Self.emptyStateItems() : items
    }
  }

  private func browseChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    deferredLoadState.requestLoadIfNeeded { [weak self] in
      self?.rescanHandler?()
    }

    let children = childrenStore.readValue { $0 }
    if !children.isEmpty || deferredLoadState.didCompleteLoad {
      return children
    }

    return [NotionCatalogSupport.loadingMessageItem()]
  }

  private nonisolated static func search(query: String) async throws -> [CatalogItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let connections = NotionCatalogSupport.connections(for: NotionCatalog.self)
    guard !connections.isEmpty else {
      return [NotionCatalogSupport.authRequiredMessageItem()]
    }

    if trimmed.isEmpty {
      let items = try await loadRecentItems(connections: connections)
      return items.isEmpty ? emptyStateItems() : items
    }

    let totalConnections = connections.count
    let results = try await NotionCatalogSupport.loadPerConnection(connections) { connection in
      let client = NotionAPIClient(connection: connection)
      return try await client.search(query: trimmed)
    }

    return NotionCatalogSupport.catalogItems(from: results, totalConnections: totalConnections)
  }

  private nonisolated static func loadRecentItems(connections: [NotionConnection]) async throws
    -> [CatalogItem]
  {
    let totalConnections = connections.count
    let results = try await NotionCatalogSupport.loadPerConnection(connections) { connection in
      let client = NotionAPIClient(connection: connection)
      return try await client.fetchRecentItems()
    }

    return NotionCatalogSupport.catalogItems(from: results, totalConnections: totalConnections)
  }

  private nonisolated static func emptyStateItems() -> [CatalogItem] {
    [
      NotionCatalogSupport.emptyStateItem(
        title: "No shared pages",
        message: "Share a page or data source with this Notion integration to see it here."
      )
    ]
  }
}

public final class NotionPagesCatalog: Catalog, RescanSchedulingCatalog, StartupScanningCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?

  private let pagesStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let deferredLoadState = DeferredCatalogLoadState()

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Pages",
    id: "notion.pages",
    detail: "Top-level Notion pages",
    catalogIcon: .init(symbolName: "book.pages", color: .gray),
    configuration: ScopedSearchConfiguration(debounce: .milliseconds(300), searchOnChange: true),
    childrenProvider: { [weak self] in
      self?.browseChildren() ?? []
    },
    searchHandler: { query in
      try await Self.searchPages(query: query)
    }
  )

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    return [rootItem] + pagesStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func releaseRetainedState() {
    pagesStore.value = []
    messageStore.value = nil
    deferredLoadState.reset()
  }

  public func scan() async {
    defer { deferredLoadState.markLoadCompleted() }
    await NotionCatalogSupport.scan(
      for: NotionPagesCatalog.self,
      identifier: identifier,
      messageStore: messageStore,
      onMissingConnections: { pagesStore.value = [] },
      onError: { pagesStore.value = [] }
    ) { connections in
      pagesStore.value = try await Self.loadTopLevelPages(connections: connections)
    }
  }

  private func browseChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    deferredLoadState.requestLoadIfNeeded { [weak self] in
      self?.rescanHandler?()
    }

    let pages = pagesStore.readValue { $0 }
    if !pages.isEmpty {
      return pages
    }

    if deferredLoadState.didCompleteLoad {
      return Self.emptyStateItems()
    }

    return [NotionCatalogSupport.loadingMessageItem()]
  }

  private nonisolated static func searchPages(query: String) async throws -> [CatalogItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let connections = NotionCatalogSupport.connections(for: NotionPagesCatalog.self)
    guard !connections.isEmpty else {
      return [NotionCatalogSupport.authRequiredMessageItem()]
    }

    if trimmed.isEmpty {
      let items = try await loadTopLevelPages(connections: connections)
      return items.isEmpty ? emptyStateItems() : items
    }

    let totalConnections = connections.count
    let results = try await NotionCatalogSupport.loadPerConnection(connections) { connection in
      let client = NotionAPIClient(connection: connection)
      return try await client.searchPages(query: trimmed)
    }

    return NotionCatalogSupport.catalogItems(from: results, totalConnections: totalConnections)
  }

  private nonisolated static func loadTopLevelPages(connections: [NotionConnection]) async throws
    -> [CatalogItem]
  {
    let totalConnections = connections.count
    let results = try await NotionCatalogSupport.loadPerConnection(connections) { connection in
      let client = NotionAPIClient(connection: connection)
      return try await client.fetchTopLevelPages()
    }

    return NotionCatalogSupport.catalogItems(from: results, totalConnections: totalConnections)
  }

  private nonisolated static func emptyStateItems() -> [CatalogItem] {
    [
      NotionCatalogSupport.emptyStateItem(
        title: "No top-level pages",
        message: "Share top-level pages with this Notion integration to add them to Tuna search."
      )
    ]
  }
}
