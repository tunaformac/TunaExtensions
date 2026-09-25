import Foundation
import TunaKit

public final class FantasticalCatalog: NSObject, Catalog {
  public let identifier: String
  public let name: String

  public var objects: [CatalogItem] {
    Self.makeItems(calendarSets: FantasticalSettings.calendarSetNames)
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func scan() async {}

  static func makeItems(calendarSets: [String]) -> [CatalogItem] {
    var destinations: [FantasticalDestination] = [.today, .tomorrow, .calendar, .miniWindow]
    destinations.append(contentsOf: calendarSets.map(FantasticalDestination.calendarSet))
    let entries: [CatalogItem] = [
      FantasticalNewItemRoot(task: false), FantasticalNewItemRoot(task: true),
    ]
    return entries + destinations.map(FantasticalDestinationItem.init(destination:))
  }
}
