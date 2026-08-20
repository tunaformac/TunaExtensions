import Foundation
import TunaKit

public final class MyMindCatalog: Catalog, CatalogViewProviding,
  CatalogGridConfigurationProviding, CatalogSortingProviding, StartupScanningCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = MyMindCatalogRootItem(
    title: "mymind",
    id: "mymind",
    detail: "Search and browse objects in your mind",
    catalogIcon: .init(symbolName: "brain", color: .purple),
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: { try await Self.loadObjects() },
    searchPageHandler: { query, page in try await Self.searchPage(query: query, page: page) }
  )

  public let resultsViewStyle = CatalogResultsView.grid
  public let gridConfiguration = MyMindCatalogSupport.gridConfiguration
  public let sortOptions = [CatalogSortOption.capturedAtDescending]
  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async {
    rootItem.reset()
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  public func releaseRetainedState() {
    rootItem.reset()
  }

  private nonisolated static func loadObjects() async throws -> [CatalogItem] {
    let credentials = try MyMindSettings.credentials(for: MyMindCatalog.self)
    let objects = try await MyMindAPIClient(credentials: credentials).listObjects(limit: 40)
    return objects.isEmpty
      ? [MyMindCatalogSupport.emptyItem(
          title: "Your mind is empty",
          message: "Save something to mymind to see it here."
        )]
      : objects.map { MyMindObjectItem(object: $0, credentials: credentials) }
  }

  private nonisolated static func searchPage(query: String, page: Int) async throws
    -> ScopedSearchPage
  {
    let credentials = try MyMindSettings.credentials(for: MyMindCatalog.self)
    let result = try await MyMindAPIClient(credentials: credentials)
      .searchObjectsPage(query: query, page: page)
    let items: [CatalogItem] = if result.objects.isEmpty && page == 1 {
      [MyMindCatalogSupport.emptyItem(
        title: "No matches",
        message: "No mymind objects matched your search."
      )]
    } else {
      result.objects.map { MyMindObjectItem(object: $0, credentials: credentials) }
    }
    return ScopedSearchPage(items: items, hasMore: result.hasMore)
  }
}

public final class MyMindSpacesCatalog: Catalog, CatalogViewProviding,
  CatalogGridConfigurationProviding, CatalogSortingProviding, RescanSchedulingCatalog,
  StartupScanningCatalog, RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?
  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let deferredLoadState = DeferredCatalogLoadState()

  private lazy var rootItem = BrowseCatalogItem(
    title: "mymind Spaces",
    id: "mymind.spaces",
    detail: "Browse your mymind Spaces",
    catalogIcon: .init(symbolName: "square.grid.2x2", color: .purple),
    childrenProvider: { [weak self] in self?.browseChildren() ?? [] }
  )

  public let resultsViewStyle = CatalogResultsView.grid
  public let gridConfiguration = MyMindCatalogSupport.gridConfiguration
  public let sortOptions = [CatalogSortOption.capturedAtDescending]
  public var objects: [CatalogItem] { [rootItem] + itemsStore.readValue { $0 } }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  @MainActor public func scan() async {
    defer { deferredLoadState.markLoadCompleted() }
    do {
      let credentials = try MyMindSettings.credentials(for: MyMindSpacesCatalog.self)
      let spaces = try await MyMindAPIClient(credentials: credentials).listSpaces()
      itemsStore.value = spaces.map {
        MyMindSpaceItem(
          space: $0,
          credentials: credentials,
          catalogIdentifier: identifier
        )
      }
    } catch MyMindAPIError.credentialsRequired {
      itemsStore.value = [MyMindCatalogSupport.authRequiredItem()]
    } catch {
      itemsStore.value = [MyMindCatalogSupport.errorItem(error)]
    }
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  public func releaseRetainedState() {
    itemsStore.value = []
    deferredLoadState.reset()
  }

  private func browseChildren() -> [CatalogItem] {
    deferredLoadState.requestLoadIfNeeded { [weak self] in self?.rescanHandler?() }
    let items = itemsStore.readValue { $0 }
    if !items.isEmpty { return items }
    if deferredLoadState.didCompleteLoad {
      return [MyMindCatalogSupport.emptyItem(
        title: "No Spaces",
        message: "Create a Space in mymind to see it here."
      )]
    }
    return [MyMindCatalogSupport.loadingItem("your Spaces")]
  }
}
