import AppKit
import Foundation
import TunaKit

@MainActor
public final class NotesCatalog: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let newNoteItem = NotesNewNoteItem()

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }
    return [newNoteItem] + itemsStore.readValue { $0 }
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
      NotesDatabase.fetchNotes()
    }.value

    switch result {
    case .success(let records):
      messageStore.value = nil
      itemsStore.value = records.map { record in
        NoteItem(
          title: record.title,
          identifier: record.identifier,
          folderName: record.folderName,
          snippet: record.snippet,
          modifiedAt: record.modifiedAt
        )
      }
    case .failure(let error):
      itemsStore.value = []
      messageStore.value = [
        CatalogMessageItem(
          title: error.title,
          message: error.message,
          symbolName: error.symbolName,
          tintColor: .systemOrange
        )
      ]
    }

    reportScanFinished()
  }
}
