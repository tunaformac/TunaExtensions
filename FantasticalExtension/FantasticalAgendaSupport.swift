import AppKit
import Foundation
import TunaKit

enum FantasticalAgendaSupport {
  static let agendaDays = 7

  /// Posted after this extension changes something in Fantastical so cached agenda drops.
  static let didChange = Notification.Name("com.brnbw.tuna.plugins.fantastical.agendaDidChange")

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
    if let overdue = FantasticalAgendaRange.overdueWhen(now: now, calendar: calendar) {
      perRange[.tasks] = deduplicated(try await items(when: overdue) + (perRange[.tasks] ?? []))
    }
    let pool = dayPool(from: perRange)
    for derived in [FantasticalAgendaRange.today, .tomorrow] {
      let interval = derived.interval(now: now, calendar: calendar)
      perRange[derived] = pool.filter { $0.overlaps(interval, calendar: calendar) }
    }
    return sections(from: perRange, calendars: calendars, now: now, calendar: calendar)
  }

  static func sections(
    from perRange: [FantasticalAgendaRange: [FantasticalAgendaItem]], calendars: [FantasticalCalendar],
    now: Date, calendar: Calendar = .autoupdatingCurrent
  ) -> [CatalogItem] {
    let byID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func entities(_ subset: [FantasticalAgendaItem]) -> [CatalogItem] {
      subset.map { entity(for: $0, calendars: calendars, now: now) }
    }
    func subset(_ range: FantasticalAgendaRange) -> [FantasticalAgendaItem] {
      let found = sorted(perRange[range] ?? [])
      guard range.tasksOnly else { return found }
      return found.filter { isTask($0, in: byID[$0.calendarID]) }
    }

    var sections: [CatalogItem] = FantasticalAgendaRange.allCases.map { range in
      let found = subset(range)
      let detail =
        range.tasksOnly
        ? tasksDetail(found, calendars: calendars, now: now, calendar: calendar)
        : sectionDetail(found.count, window: range.windowDescription)
      return FantasticalSectionItem(
        title: range.title, id: "fantastical.agenda.\(range)",
        detail: detail,
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
      item: item, calendarTitle: cal?.title, isTask: isTask(item, in: cal),
      isEditable: cal?.isWritable ?? true, now: now)
  }

  /// What Today and Tomorrow are sliced from: every window that already reaches back before
  /// today, so an item that started earlier and is still running is not lost with the seven day
  /// query it falls outside of.
  static func dayPool(from perRange: [FantasticalAgendaRange: [FantasticalAgendaItem]])
    -> [FantasticalAgendaItem]
  {
    deduplicated([.next7Days, .thisWeek, .thisMonth].flatMap { perRange[$0] ?? [] })
  }

  static func deduplicated(_ items: [FantasticalAgendaItem]) -> [FantasticalAgendaItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
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

  /// The helper marks nothing as a task. A calendar that holds only tasks settles it; in one that
  /// holds both, an event always carries an end and a task never does.
  static func isTask(_ item: FantasticalAgendaItem, in calendar: FantasticalCalendar?) -> Bool {
    guard let calendar, calendar.supportsTasks else { return false }
    return !calendar.supportsEvents || item.end == nil
  }

  /// Says how much of the Tasks group is already due, because "12 items" hides the three that
  /// needed doing last week, and says when Fantastical reports no list that could hold one.
  static func tasksDetail(
    _ items: [FantasticalAgendaItem], calendars: [FantasticalCalendar], now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    guard calendars.contains(where: \.supportsTasks) else { return "0 items, no task lists" }
    let startOfToday = calendar.startOfDay(for: now)
    let overdue = items.filter { ($0.start ?? .distantFuture) < startOfToday }.count
    guard overdue > 0 else {
      return sectionDetail(items.count, window: FantasticalAgendaRange.tasks.windowDescription)
    }
    let upcoming = items.count - overdue
    return "\(overdue) overdue, \(upcoming) next \(FantasticalAgendaRange.taskWindowDays) days"
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

  /// Counts the writes this extension has made, so a browse node built before one can tell the
  /// rows it is holding are out of date.
  static let dataGeneration = LockedValue<Int>(0)

  static func postDataDidChange() {
    dataGeneration.withValue { $0 += 1 }
    FantasticalNewItemRoot.invalidateCalendars()
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}
