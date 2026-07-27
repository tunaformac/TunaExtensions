import AppKit
import Foundation
import TunaKit

public final class BrewCatalog: BrewCatalogBase {}

public final class BrewSearchCatalog: BrewCatalogBase {}

@MainActor
public class BrewCatalogBase: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private lazy var homebrewEntry = BrewMetaItem(
    title: "Homebrew",
    detail: "Search Homebrew packages and casks"
  )

  public var objects: [CatalogItem] { [homebrewEntry] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
  }

  public func releaseRetainedState() {}

  public func scan() async {
    reportScanFinished()
  }
}
