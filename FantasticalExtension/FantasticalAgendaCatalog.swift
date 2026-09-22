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

enum FantasticalAgendaSupport {
  static let agendaDays = 7

  /// Last calendars the helper returned, so browse children can be built without awaiting.
  static let knownCalendars = LockedValue<[FantasticalCalendar]>([])

  static func calendars() async throws -> [FantasticalCalendar] {
    let result = try await FantasticalMCPClient.shared.call("queryCalendars")
    let calendars = try FantasticalAgendaParser.calendars(from: result.text)
    knownCalendars.value = calendars
    return calendars
  }

  static func items(when: String?, query: String? = nil) async throws -> [FantasticalAgendaItem] {
    var arguments: [String: Any] = [:]
    if let when { arguments["when"] = when }
    if let query, !query.isEmpty { arguments["query"] = query }
    let result = try await FantasticalMCPClient.shared.call("queryCalendarItems", arguments: arguments)
    return try FantasticalAgendaParser.items(from: result.text)
  }

  /// The helper returns at most this many items per query, so each group gets its own query
  /// instead of slicing one long range (which would run out before today).
  static let resultCap = 99

  static func browseChildren() async throws -> [CatalogItem] {
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let calendars = try await calendars()
    var perRange: [FantasticalAgendaRange: [FantasticalAgendaItem]] = [:]
    for range in FantasticalAgendaRange.queried {
      perRange[range] = try await items(when: range.when(now: now, calendar: calendar))
    }
    let week = perRange[.next7Days] ?? []
    for derived in [FantasticalAgendaRange.today, .tomorrow] {
      let interval = derived.interval(now: now, calendar: calendar)
      perRange[derived] = week.filter { $0.overlaps(interval) }
    }
    return sections(from: perRange, calendars: calendars, now: now, calendar: calendar)
  }

  static func sections(
    from perRange: [FantasticalAgendaRange: [FantasticalAgendaItem]], calendars: [FantasticalCalendar],
    now: Date, calendar: Calendar = .autoupdatingCurrent
  ) -> [CatalogItem] {
    let taskCalendars = Set(calendars.filter { $0.supportsTasks && !$0.supportsEvents }.map(\.id))
    func entities(_ subset: [FantasticalAgendaItem]) -> [CatalogItem] {
      subset.map { entity(for: $0, calendars: calendars, now: now) }
    }
    func subset(_ range: FantasticalAgendaRange) -> [FantasticalAgendaItem] {
      let found = sorted(perRange[range] ?? [])
      return range.tasksOnly ? found.filter { taskCalendars.contains($0.calendarID) } : found
    }

    var sections: [CatalogItem] = FantasticalAgendaRange.allCases.map { range in
      let found = subset(range)
      return FantasticalSectionItem(
        title: range.title, id: "fantastical.agenda.\(range)",
        detail: sectionDetail(found.count, window: range.windowDescription),
        symbolName: range.symbolName, iconColor: range.iconColor, children: entities(found),
        sortOrder: range.sortOrder)
    }

    let week = subset(.next7Days)
    let perCalendar: [CatalogItem] = calendars.enumerated().compactMap { index, cal in
      let mine = week.filter { $0.calendarID == cal.id }
      guard !mine.isEmpty else { return nil }
      return FantasticalSectionItem(
        title: cal.title, id: "fantastical.agenda.calendar.\(cal.id)", detail: count(mine.count),
        symbolName: cal.supportsTasks ? "checklist" : "calendar",
        iconColor: cal.supportsTasks ? .blue : .red, children: entities(mine), sortOrder: index)
    }
    if !perCalendar.isEmpty {
      sections.append(
        FantasticalSectionItem(
          title: "By Calendar", id: "fantastical.agenda.by-calendar",
          detail: "\(perCalendar.count) calendars, next 7 days", symbolName: "folder",
          iconColor: .gray, children: perCalendar, sortOrder: 7))
    }
    return sections
  }

  static func search(query: String) async throws -> [CatalogItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    async let calendarsTask = calendars()
    let found: [FantasticalAgendaItem]
    if trimmed.isEmpty {
      let end = calendar.date(byAdding: .day, value: agendaDays, to: now) ?? now
      found = try await items(when: FantasticalWhen.range(from: now, to: end, calendar: calendar))
    } else {
      found = try await items(when: nil, query: trimmed)
    }
    let calendars = try await calendarsTask
    let entities = sorted(found).prefix(60).map { entity(for: $0, calendars: calendars, now: now) }
    guard !entities.isEmpty else {
      return [
        messageItem(
          title: trimmed.isEmpty ? "Nothing scheduled" : "No matches",
          message: trimmed.isEmpty
            ? "No events or tasks in the next \(agendaDays) days."
            : "Fantastical has nothing matching \u{201C}\(trimmed)\u{201D}.",
          symbolName: "magnifyingglass", tint: .secondaryLabelColor)
      ]
    }
    return Array(entities)
  }

  static func entity(for item: FantasticalAgendaItem, calendars: [FantasticalCalendar], now: Date)
    -> FantasticalAgendaEntity
  {
    let cal = calendars.first { $0.id == item.calendarID }
    return FantasticalAgendaEntity(
      item: item, calendarTitle: cal?.title, isTask: cal?.supportsTasks == true && cal?.supportsEvents == false,
      now: now)
  }

  static func sorted(_ items: [FantasticalAgendaItem]) -> [FantasticalAgendaItem] {
    items.sorted { lhs, rhs in
      switch (lhs.start, rhs.start) {
      case (let l?, let r?) where l != r: return l < r
      case (.some, .none): return true
      case (.none, .some): return false
      default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }
  }

  static func sectionDetail(_ n: Int, window: String?) -> String {
    guard let window else { return count(n) }
    return "\(count(n)), \(window)"
  }

  static func count(_ n: Int) -> String {
    if n >= resultCap { return "\(resultCap)+ items, Fantastical returns the first \(resultCap)" }
    return n == 1 ? "1 item" : "\(n) items"
  }

  static func messageItem(title: String, message: String, symbolName: String, tint: NSColor) -> CatalogItem {
    CatalogMessageItem(title: title, message: message, symbolName: symbolName, tintColor: tint)
  }

  static func errorItem(_ error: Error) -> CatalogItem {
    let mcpError = error as? FantasticalMCPError
    return CatalogMessageItem(
      title: mcpError?.title ?? "Fantastical request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange)
  }

  static func postScanFinished(identifier: String) {
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  static func postDataDidChange() {
    FantasticalNewItemRoot.invalidateCalendars()
    NotificationCenter.default.post(name: FantasticalAgendaDidChange, object: nil)
  }

  static let previewGraceSeconds = 5

  /// A create lands when Fantastical writes it: at once with "Add without confirmation", only
  /// after the user's Enter in the parse preview otherwise, which the second drop covers.
  static func postDataDidChangeAfterCreate(previewShown: Bool) {
    postDataDidChange()
    guard previewShown else { return }
    Task {
      try? await Task.sleep(for: .seconds(previewGraceSeconds))
      postDataDidChange()
    }
  }
}
