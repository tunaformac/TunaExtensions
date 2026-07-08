import AppKit
import Foundation
import TunaKit

public final class NotesCatalog: NotesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .all)
  }
}

public final class NotesSearchCatalog: NotesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .search)
  }
}

@MainActor
public class NotesCatalogBase: NSObject, Catalog, RetainedCatalogStateReleasing {
  enum Mode {
    case all
    case search
  }

  public let identifier: String
  public let name: String
  private let mode: Mode
  private let notificationCenter: NotificationCenter

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let newNoteItem = NotesNewNoteItem()

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    switch mode {
    case .all:
      return itemsStore.readValue { $0 }
    case .search:
      return [newNoteItem] + NotesActionsCatalog.actions()
    }
  }

  fileprivate init(
    definition: CatalogDefinition,
    mode: Mode,
    notificationCenter: NotificationCenter = .default
  ) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.mode = mode
    self.notificationCenter = notificationCenter
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Notes catalog type instead.")
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
      NotesDatabase.fetchNotes()
    }.value

    switch result {
    case .success(let records):
      messageStore.value = nil

      let items: [CatalogItem] = records.map { record in
        NoteItem(
          title: record.title,
          identifier: record.identifier,
          folderName: record.folderName,
          snippet: record.snippet,
          modifiedAt: record.modifiedAt
        )
      }

      switch mode {
      case .all:
        itemsStore.value = items
      case .search:
        break
      }

    case .failure(let error):
      itemsStore.value = []

      let tintColor: NSColor
      switch error.tint {
      case .orange:
        tintColor = .systemOrange
      }

      messageStore.value = [
        CatalogMessageItem(
          title: error.title,
          message: error.message,
          symbolName: error.symbolName,
          tintColor: tintColor
        )
      ]
    }

    reportScanFinished()
  }
}
