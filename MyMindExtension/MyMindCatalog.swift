import Foundation
import TunaKit

public final class MyMindCatalog: Catalog, CatalogViewProviding,
  CatalogGridConfigurationProviding, CatalogSortingProviding, RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  private let itemsStore = LockedValue<[CatalogItem]>([])

  public let resultsViewStyle = CatalogResultsView.grid
  public let gridConfiguration = MyMindCatalogSupport.gridConfiguration
  public let sortOptions = [CatalogSortOption.capturedAtDescending]
  public var objects: [CatalogItem] { itemsStore.readValue { $0 } }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  @MainActor public func scan() async {
    do {
      let credentials = try MyMindSettings.credentials(for: MyMindCatalog.self)
      let objects = try await MyMindAPIClient(credentials: credentials).listObjects(limit: 10_000)
      itemsStore.value = objects.map {
        MyMindObjectItem(object: $0, credentials: credentials)
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
  }
}

public final class MyMindSpacesCatalog: Catalog, CatalogViewProviding,
  CatalogGridConfigurationProviding, CatalogSortingProviding, RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  private let itemsStore = LockedValue<[CatalogItem]>([])

  public let resultsViewStyle = CatalogResultsView.grid
  public let gridConfiguration = MyMindCatalogSupport.gridConfiguration
  public let sortOptions = [CatalogSortOption.capturedAtDescending]
  public var objects: [CatalogItem] { itemsStore.readValue { $0 } }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  @MainActor public func scan() async {
    do {
      let credentials = try MyMindSettings.credentials(for: MyMindSpacesCatalog.self)
      let spaces = try await MyMindAPIClient(credentials: credentials).listSpaces()
      itemsStore.value = spaces.isEmpty
        ? [MyMindCatalogSupport.emptyItem(
            title: "No Spaces",
            message: "Create a Space in mymind to see it here."
          )]
        : spaces.map {
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
  }
}
