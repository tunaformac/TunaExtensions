import AppKit
import Foundation
import TunaKit

/// Posted after this extension changes something in Fantastical so cached agenda drops.
let FantasticalAgendaDidChange = Notification.Name("com.brnbw.tuna.plugins.fantastical.agendaDidChange")

/// Live-search root: type to search events and tasks, or browse the next days.
public final class FantasticalAgendaCatalog: Catalog, StartupScanningCatalog {
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

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

  public var objects: [CatalogItem] { itemsStore.readValue { $0 } }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func scan() async {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      itemsStore.value = []
      reportScanFinished()
      return
    }
    do {
      let calendars = try await FantasticalAgendaSupport.calendars().filter(\.isWritable)
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

  static func calendars() async throws -> [FantasticalCalendar] {
    let result = try await FantasticalMCPClient.shared.call("queryCalendars")
    return try FantasticalAgendaParser.calendars(from: result.text)
  }

  static func items(when: String?, query: String? = nil) async throws -> [FantasticalAgendaItem] {
    var arguments: [String: Any] = [:]
    if let when { arguments["when"] = when }
    if let query, !query.isEmpty { arguments["query"] = query }
    let result = try await FantasticalMCPClient.shared.call("queryCalendarItems", arguments: arguments)
    return try FantasticalAgendaParser.items(from: result.text)
  }

  static func browseChildren() async throws -> [CatalogItem] {
    let calendars = try await calendars()
    let identifier = FantasticalIdentifiers.agendaCatalog
    var sections: [CatalogItem] = FantasticalAgendaRange.allCases.map { range in
      FantasticalRangeSectionItem(
        title: range.title, id: "fantastical.agenda.\(range)", symbolName: range.symbolName,
        iconColor: range.iconColor, catalogIdentifier: identifier
      ) {
        try await load(range: range, calendars: calendars)
      }
    }

    let perCalendar: [CatalogItem] = calendars.filter(\.isWritable).map { cal in
      FantasticalRangeSectionItem(
        title: cal.title, id: "fantastical.agenda.calendar.\(cal.id)",
        symbolName: cal.supportsTasks ? "checklist" : "calendar",
        iconColor: cal.supportsTasks ? .blue : .red, catalogIdentifier: identifier
      ) {
        try await load(range: .next7Days, calendars: calendars, calendarID: cal.id)
      }
    }
    if !perCalendar.isEmpty {
      sections.append(
        FantasticalSectionItem(
          title: "By Calendar", id: "fantastical.agenda.by-calendar",
          detail: "\(perCalendar.count) calendars, next 7 days", symbolName: "folder",
          iconColor: .gray, children: perCalendar))
    }
    return sections
  }

  static func load(
    range: FantasticalAgendaRange, calendars: [FantasticalCalendar], calendarID: String? = nil,
    now: Date = Date()
  ) async throws -> [CatalogItem] {
    var arguments: [String: Any] = ["when": range.when(now: now)]
    if let calendarID { arguments["calendarId"] = calendarID }
    let result = try await FantasticalMCPClient.shared.call("queryCalendarItems", arguments: arguments)
    var items = try FantasticalAgendaParser.items(from: result.text)
    if range.tasksOnly {
      let taskCalendars = Set(calendars.filter { $0.supportsTasks && !$0.supportsEvents }.map(\.id))
      items = items.filter { taskCalendars.contains($0.calendarID) }
    }
    return sorted(items).map { entity(for: $0, calendars: calendars, now: now) }
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

  /// Dated items soonest first, undated last by title.
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

  static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

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
    NotificationCenter.default.post(name: FantasticalAgendaDidChange, object: nil)
  }
}
