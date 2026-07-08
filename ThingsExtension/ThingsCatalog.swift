import Foundation
import TunaKit

public final class ThingsCatalog: NSObject, Catalog {
  public let identifier: String
  public let name: String

  private let items: [CatalogItem]

  public var objects: [CatalogItem] {
    items
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.items = Self.makeItems()
    super.init()
  }

  public func scan() async {}
}

extension ThingsCatalog {
  fileprivate struct ListDefinition {
    let title: String
    let listID: String
    let symbolName: String
    let detail: String
  }

  fileprivate static func makeItems() -> [CatalogItem] {
    let lists: [ListDefinition] = [
      ListDefinition(
        title: "Inbox",
        listID: "inbox",
        symbolName: "tray",
        detail: "Tasks without a list"
      ),
      ListDefinition(
        title: "Today",
        listID: "today",
        symbolName: "sun.max",
        detail: "Tasks scheduled for today"
      ),
      ListDefinition(
        title: "Upcoming",
        listID: "upcoming",
        symbolName: "calendar",
        detail: "Tasks with upcoming dates"
      ),
      ListDefinition(
        title: "Anytime",
        listID: "anytime",
        symbolName: "clock",
        detail: "Tasks without a schedule"
      ),
      ListDefinition(
        title: "Someday",
        listID: "someday",
        symbolName: "sparkles",
        detail: "Tasks for later"
      ),
      ListDefinition(
        title: "Logbook",
        listID: "logbook",
        symbolName: "archivebox",
        detail: "Completed tasks"
      ),
      ListDefinition(
        title: "Tomorrow",
        listID: "tomorrow",
        symbolName: "calendar.badge.clock",
        detail: "Tasks scheduled for tomorrow"
      ),
      ListDefinition(
        title: "Deadlines",
        listID: "deadlines",
        symbolName: "flag.checkered",
        detail: "Tasks with deadlines"
      ),
      ListDefinition(
        title: "Repeating",
        listID: "repeating",
        symbolName: "repeat",
        detail: "Repeating tasks"
      ),
      ListDefinition(
        title: "All Projects",
        listID: "all-projects",
        symbolName: "square.stack.3d.up",
        detail: "All projects"
      ),
      ListDefinition(
        title: "Logged Projects",
        listID: "logged-projects",
        symbolName: "checkmark.circle",
        detail: "Completed projects"
      ),
    ]

    let items: [CatalogItem] = lists.map { list in
      ThingsListItem(
        title: list.title,
        listID: list.listID,
        symbolName: list.symbolName,
        detail: list.detail
      )
    }

    return items
  }
}
