import AppKit
import Foundation
import OSLog
import TunaKit

extension FantasticalAgendaSupport {
  static let log = Logger(subsystem: "com.brnbw.tuna.plugins.fantastical", category: "tasks")

  /// Open tasks come from wherever Fantastical itself reads them: EventKit for a Reminders list,
  /// Fantastical's own store for the accounts it syncs, and only then the helper, which returns
  /// the finished tasks of a list and drops its open undated ones.
  static func openTaskLists(
    calendars: [FantasticalCalendar], now: Date, calendar: Calendar
  ) async throws -> (lists: [FantasticalTaskList], reminderAccessDenied: Bool) {
    let taskCalendars = calendars.filter { $0.supportsTasks && !$0.supportsEvents }
    guard !taskCalendars.isEmpty else { return ([], false) }
    let reminders = FantasticalReminderStore.shared
    let wantsReminders = taskCalendars.contains { $0.sourceName == FantasticalReminderStore.helperSourceName }
    let access: FantasticalReminderStore.Access = wantsReminders ? await reminders.access() : .denied
    let reminderLists = access == .granted ? await reminders.listIdentifiers() : []
    let store = FantasticalStoreReader()
    var lists: [FantasticalTaskList] = []
    for cal in taskCalendars {
      try Task.checkCancellation()
      let source = taskSource(for: cal, reminderLists: reminderLists, storeAvailable: store.isAvailable)
      log.info("list \(cal.id, privacy: .public) via \(String(describing: source), privacy: .public)")
      switch source {
      case .eventKit:
        lists.append(FantasticalTaskList(calendar: cal, source: .eventKit, items: await reminders.openTasks(in: cal.id)))
        continue
      case .store:
        do {
          lists.append(FantasticalTaskList(calendar: cal, source: .store, items: try store.openTasks(in: cal.id)))
          continue
        } catch {
          FantasticalStoreReader.log.error("store read failed: \(error.localizedDescription, privacy: .public)")
        }
      case .helper:
        break
      }
      let when = FantasticalAgendaRange.taskWhen(now: now, calendar: calendar)
      let day = calendar.startOfDay(for: now)
      let horizon = calendar.date(byAdding: .day, value: FantasticalAgendaRange.taskWindowDays, to: day) ?? day
      let rows = try await items(when: when, calendarID: cal.id)
      lists.append(
        FantasticalTaskList(
          calendar: cal, source: .helper,
          items: deduplicated(rows).filter { $0.start.map { $0 < horizon } ?? false }))
    }
    return (lists, wantsReminders && access == .denied)
  }

  /// A Reminders list is never in Fantastical's store, so without EventKit access only the helper
  /// can show it.
  static func taskSource(
    for calendar: FantasticalCalendar, reminderLists: Set<String>, storeAvailable: Bool
  ) -> FantasticalTaskSource {
    if reminderLists.contains(calendar.id) { return .eventKit }
    if calendar.sourceName == FantasticalReminderStore.helperSourceName { return .helper }
    return storeAvailable ? .store : .helper
  }

  static func taskSections(
    lists: [FantasticalTaskList], reminderAccessDenied: Bool = false, now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> (children: [CatalogItem], detail: String) {
    let calendars = lists.map(\.calendar)
    let sourceByList = Dictionary(lists.map { ($0.calendar.id, $0.source) }, uniquingKeysWith: { first, _ in first })
    let all = lists.flatMap(\.items)
    let overdue = sortedTasks(all.filter { $0.isOverdue(now: now, calendar: calendar) })
    var children: [CatalogItem] = []
    if reminderAccessDenied {
      children.append(
        FantasticalNoticeItem(
          title: "Reminders access needed",
          message: "Allow Tuna under System Settings, Privacy & Security, Reminders, then open Tasks again.",
          symbolName: "lock", tint: .systemOrange))
    }
    if !overdue.isEmpty {
      children.append(
        FantasticalSectionItem(
          title: "Overdue", id: "fantastical.agenda.tasks.overdue", detail: plainCount(overdue.count),
          symbolName: "exclamationmark.circle", iconColor: .red,
          children: overdue.map { entity(for: $0, calendars: calendars, now: now, source: sourceByList[$0.calendarID] ?? .helper) },
          sortOrder: 0))
    }
    for (index, list) in lists.enumerated() {
      children.append(
        FantasticalSectionItem(
          title: list.calendar.title, id: "fantastical.agenda.tasks.\(list.calendar.id)",
          detail: listDetail(list), symbolName: "checklist", iconColor: .blue,
          children: sortedTasks(list.items).map { entity(for: $0, calendars: calendars, now: now, source: list.source) },
          sortOrder: index + 1))
    }
    return (children, tasksDetail(open: all.count, overdue: overdue.count, hasLists: !lists.isEmpty))
  }

  private static func plainCount(_ n: Int) -> String {
    n == 1 ? "1 item" : "\(n) items"
  }

  static func listDetail(_ list: FantasticalTaskList) -> String {
    guard !list.items.isEmpty else { return "No open tasks" }
    guard list.source == .helper else { return "\(list.items.count) open" }
    return "\(list.items.count) dated, completion unknown"
  }

  static func tasksDetail(open: Int, overdue: Int, hasLists: Bool) -> String {
    guard hasLists else { return "0 items, no task lists" }
    guard open > 0 else { return "No open tasks" }
    guard overdue > 0 else { return "\(open) open" }
    return "\(open) open, \(overdue) overdue"
  }

  /// Due soonest first, undated last, priority breaking ties, then the title.
  static func sortedTasks(_ items: [FantasticalAgendaItem]) -> [FantasticalAgendaItem] {
    items.sorted { lhs, rhs in
      switch (lhs.start, rhs.start) {
      case (let l?, let r?) where l != r: return l < r
      case (.some, .none): return true
      case (.none, .some): return false
      default:
        if lhs.priorityRank != rhs.priorityRank { return lhs.priorityRank < rhs.priorityRank }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }
  }
}
