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
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let end = calendar.date(byAdding: .day, value: agendaDays, to: now) ?? now
    async let calendarsTask = calendars()
    async let itemsTask = items(when: FantasticalWhen.range(from: now, to: end, calendar: calendar))
    let calendars = try await calendarsTask
    let items = sorted(try await itemsTask)
    let entities = items.map { entity(for: $0, calendars: calendars, now: now) }

    var grouped: [FantasticalAgendaBucket: [CatalogItem]] = [:]
    for (item, entity) in zip(items, entities) {
      guard let bucket = FantasticalAgendaBucket.bucket(for: item, now: now, calendar: calendar) else { continue }
      grouped[bucket, default: []].append(entity)
    }
    var sections: [CatalogItem] = FantasticalAgendaBucket.allCases.compactMap { bucket in
      guard let children = grouped[bucket], !children.isEmpty else { return nil }
      return FantasticalSectionItem(
        title: bucket.title, id: "fantastical.agenda.\(bucket)",
        detail: count(children.count), symbolName: bucket.symbolName,
        iconColor: bucket.iconColor.tunaColor, children: children)
    }

    let byCalendar: [CatalogItem] = calendars.filter(\.isWritable).compactMap { cal in
      let children = zip(items, entities).filter { $0.0.calendarID == cal.id }.map(\.1)
      guard !children.isEmpty else { return nil }
      return FantasticalSectionItem(
        title: cal.title, id: "fantastical.agenda.calendar.\(cal.id)", detail: count(children.count),
        symbolName: cal.supportsTasks ? "checklist" : "calendar",
        iconColor: cal.supportsTasks ? .blue : .red, children: children)
    }
    if !byCalendar.isEmpty {
      sections.append(
        FantasticalSectionItem(
          title: "By Calendar", id: "fantastical.agenda.by-calendar",
          detail: "\(byCalendar.count) calendars", symbolName: "folder", iconColor: .gray,
          children: byCalendar))
    }

    guard !sections.isEmpty else {
      return [
        messageItem(
          title: "Nothing scheduled", message: "No events or tasks in the next \(agendaDays) days.",
          symbolName: "calendar", tint: .secondaryLabelColor)
      ]
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
