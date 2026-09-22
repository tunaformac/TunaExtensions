import AppKit
import Foundation
import TunaKit

/// Posted after this extension changes something in Fantastical so cached agenda drops.
let FantasticalAgendaDidChange = Notification.Name("com.brnbw.tuna.plugins.fantastical.agendaDidChange")

public final class FantasticalAgendaCatalog: Catalog, StartupScanningCatalog, CatalogSortingProviding,
  CatalogResultsSortModeProviding
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var sortOptions: [CatalogSortOption] { FantasticalAgendaSort.options }
  public var defaultSortOptionID: String { FantasticalAgendaSort.optionID }
  public func resultsSortMode(forSortOptionID sortOptionID: String) -> ResultsSortMode? {
    sortOptionID == FantasticalAgendaSort.optionID ? .time : nil
  }

  private var changeObserver: NSObjectProtocol?

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Fantastical",
    id: FantasticalIdentifiers.agendaCatalog,
    detail: "Search events and tasks, or browse the next days",
    catalogIcon: .init(symbolName: "calendar", color: .red),
    configuration: ScopedSearchConfiguration(debounce: .milliseconds(300), searchOnChange: true),
    loadingItemProvider: {
      CatalogLoadingItem(title: "Loading Fantastical", message: "Asking Fantastical for your agenda.")
    },
    errorItemProvider: { FantasticalAgendaSupport.errorItem($0) },
    didLoad: { [identifier] in FantasticalAgendaSupport.postScanFinished(identifier: identifier) },
    loadChildren: { try await FantasticalAgendaSupport.browseChildren() },
    searchHandler: { query in try await FantasticalAgendaSupport.search(query: query) }
  )

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    changeObserver = NotificationCenter.default.addObserver(
      forName: FantasticalAgendaDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.rootItem.reset()
        FantasticalAgendaSupport.postScanFinished(identifier: self.identifier)
      }
    }
  }

  deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
  }

  public func scan() async {
    rootItem.reset()
    FantasticalAgendaSupport.postScanFinished(identifier: identifier)
  }
}

/// Writable calendars, loaded only when an action needs a calendar target.
@MainActor
public final class FantasticalCalendarsCatalog: NSObject, Catalog, StartupScanningCatalog {
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private let itemsStore = LockedValue<[CatalogItem]>([])

  /// Where the writable calendars come from. Tests substitute a loader so a scan never reaches
  /// Fantastical's helper.
  var loadCalendars: () async throws -> [FantasticalCalendar] = {
    try await FantasticalAgendaSupport.calendars()
  }

  public var objects: [CatalogItem] { itemsStore.readValue { $0 } }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func scan() async {
    do {
      let calendars = try await loadCalendars().filter(\.isWritable)
      itemsStore.value = calendars.map(FantasticalCalendarEntity.init(calendar:))
      if calendars.isEmpty {
        itemsStore.value = [
          FantasticalAgendaSupport.messageItem(
            title: "No Writable Calendars", message: "Fantastical has no calendar Tuna can add to.",
            symbolName: "calendar.badge.exclamationmark", tint: .secondaryLabelColor)
        ]
      }
    } catch {
      itemsStore.value = [FantasticalAgendaSupport.errorItem(error)]
    }
    reportScanFinished()
  }
}
