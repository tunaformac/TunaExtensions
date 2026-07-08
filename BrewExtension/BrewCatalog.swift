import AppKit
import Foundation
import TunaKit

public final class BrewCatalog: BrewCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, includesActions: false)
  }
}

public final class BrewSearchCatalog: BrewCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, includesActions: true)
  }
}

@MainActor
public class BrewCatalogBase: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String
  private let includesActions: Bool

  private lazy var homebrewEntry = BrewMetaItem(
    title: "Homebrew",
    detail: "Search Homebrew packages and casks"
  )

  private lazy var actionItems: [CatalogItem] = BrewActionsCatalog.actions()

  public var objects: [CatalogItem] {
    includesActions ? [homebrewEntry] + actionItems : [homebrewEntry]
  }

  init(definition: CatalogDefinition, includesActions: Bool) {
    identifier = definition.identifier
    name = definition.name
    self.includesActions = includesActions
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Brew catalog type instead.")
  }

  public func releaseRetainedState() {}

  public func scan() async {
    reportScanFinished()
  }
}
