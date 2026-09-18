import AppKit
import Foundation
import TunaKit

/// The browse groups under the Fantastical root. Each one is a date window the helper
/// understands; Tasks narrows to task calendars.
enum FantasticalAgendaRange: CaseIterable, Sendable {
  case today, tomorrow, thisWeek, next7Days, thisMonth, thisQuarter, thisYear, tasks

  var title: String {
    switch self {
    case .today: return "Today"
    case .tomorrow: return "Tomorrow"
    case .thisWeek: return "This Week"
    case .next7Days: return "Next 7 Days"
    case .thisMonth: return "This Month"
    case .thisQuarter: return "This Quarter"
    case .thisYear: return "This Year"
    case .tasks: return "Tasks"
    }
  }

  var symbolName: String {
    switch self {
    case .today: return "sun.max"
    case .tomorrow: return "sunrise"
    case .thisWeek, .next7Days: return "calendar"
    case .thisMonth: return "calendar.badge.clock"
    case .thisQuarter: return "square.grid.2x2"
    case .thisYear: return "calendar.circle"
    case .tasks: return "checklist"
    }
  }

  var iconColor: CatalogIconColor {
    switch self {
    case .today: return .orange
    case .tomorrow: return .yellow
    case .thisWeek, .next7Days: return .red
    case .thisMonth: return .purple
    case .thisQuarter, .thisYear: return .gray
    case .tasks: return .blue
    }
  }

  var tasksOnly: Bool { self == .tasks }

  /// Display order in the root: Today, Tomorrow, week, month, quarter, Tasks, year; By Calendar
  /// and Next 7 Days follow.
  var sortOrder: Int {
    switch self {
    case .today: return 0
    case .tomorrow: return 1
    case .thisWeek: return 2
    case .thisMonth: return 3
    case .thisQuarter: return 4
    case .tasks: return 5
    case .thisYear: return 6
    case .next7Days: return 8
    }
  }

  func interval(now: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
    let day = calendar.startOfDay(for: now)
    func days(_ n: Int, from start: Date) -> DateInterval {
      DateInterval(start: start, end: calendar.date(byAdding: .day, value: n, to: start) ?? start)
    }
    switch self {
    case .today: return days(1, from: day)
    case .tomorrow: return days(1, from: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now) ?? days(7, from: day)
    case .next7Days: return days(7, from: day)
    case .thisMonth: return calendar.dateInterval(of: .month, for: now) ?? days(30, from: day)
    case .thisQuarter: return calendar.dateInterval(of: .quarter, for: now) ?? days(90, from: day)
    case .thisYear: return calendar.dateInterval(of: .year, for: now) ?? days(365, from: day)
    case .tasks: return days(30, from: day)
    }
  }

  /// The helper wants inclusive plain-language dates, so the exclusive end steps back a day.
  func when(now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    let interval = interval(now: now, calendar: calendar)
    let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
    if calendar.isDate(interval.start, inSameDayAs: lastDay) {
      return FantasticalWhen.day(interval.start, calendar: calendar)
    }
    return FantasticalWhen.range(from: interval.start, to: lastDay, calendar: calendar)
  }
}

/// Sections keep their declared order and outrank items; items go soonest first. Tuna's time
/// sort shows the newest `capturedAtDate` first, so timestamps are mirrored.
enum FantasticalAgendaSort {
  static let optionID = "fantastical.agenda-order"
  private static let mirrorPoint = Date(timeIntervalSinceReferenceDate: 1_500_000_000)

  static func sectionScore(_ order: Int) -> Double { 1_000_000_000_000 - Double(max(0, min(order, 10_000))) }
  static func sectionTimestamp(_ order: Int) -> Date {
    Date.distantFuture.addingTimeInterval(-Double(max(0, min(order, 10_000))))
  }
  static func itemScore(start: Date?) -> Double {
    guard let start else { return 0 }
    return 1_000 + max(0, 2 * mirrorPoint.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate)
  }
  static func itemTimestamp(start: Date?) -> Date {
    guard let start else { return .distantPast }
    return Date(timeIntervalSinceReferenceDate: 2 * mirrorPoint.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate)
  }

  static let options: [CatalogSortOption] = [
    CatalogSortOption(id: optionID, title: "Agenda", detail: "Groups in order, then soonest first", comparator: compare),
    .nameAscending,
    .nameDescending,
  ]

  static func compare(_ lhs: CatalogItem, _ rhs: CatalogItem) -> Bool {
    let l = (lhs as? ScoredCatalogItem)?.sortScore ?? -1
    let r = (rhs as? ScoredCatalogItem)?.sortScore ?? -1
    if l != r { return l > r }
    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
  }
}
