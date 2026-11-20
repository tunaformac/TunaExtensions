import AppKit
import Foundation
import TunaKit

/// Project notes and folders, as NotePlan lists them.
@MainActor
public final class NotePlanCatalog: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }
    return itemsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func releaseRetainedState() {
    itemsStore.value = []
    messageStore.value = nil
  }

  public func scan() async {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      messageStore.value = nil
      itemsStore.value = []
      reportScanFinished()
      return
    }

    let result = await Task.detached(priority: .utility) {
      NotePlanProvider.loadSnapshot()
    }.value

    switch result {
    case .success(let snapshot):
      messageStore.value = nil
      itemsStore.value = Self.items(from: snapshot)
    case .failure(let error):
      itemsStore.value = []
      messageStore.value = [
        CatalogMessageItem(
          title: error.title,
          message: error.errorDescription ?? "",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange
        )
      ]
    }

    reportScanFinished()
  }

  static func items(from snapshot: NotePlanSnapshot) -> [CatalogItem] {
    let notes: [CatalogItem] = snapshot.notes.map(NotePlanNoteItem.init(record:))
    let folders: [CatalogItem] = snapshot.folders.map(NotePlanFolderItem.init(record:))
    return notes + folders
  }
}

/// Calendar notes that always exist: today, tomorrow, this month, and so on.
public final class NotePlanDestinationsCatalog: NSObject, Catalog {
  public let identifier: String
  public let name: String

  private let items: [CatalogItem] = NotePlanCalendarPeriod.allCases.map(
    NotePlanCalendarItem.init(period:))

  public var objects: [CatalogItem] { items }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func scan() async {}
}
