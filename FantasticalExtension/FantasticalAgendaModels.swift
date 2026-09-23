import Foundation
import TunaKit

struct FantasticalCalendar: Equatable, Sendable {
  let id: String
  let title: String
  let isWritable: Bool
  let supportsEvents: Bool
  let supportsTasks: Bool
  let sourceName: String
}

struct FantasticalAgendaItem: Equatable, Sendable {
  let id: String
  let title: String
  let calendarID: String
  let start: Date?
  let end: Date?
  let location: String?
  /// The zone the helper stamped on the dates: an all-day item is a whole day in that zone, not
  /// in whichever zone Tuna runs in.
  let timeZone: TimeZone?

  init(
    id: String, title: String, calendarID: String, start: Date?, end: Date?, location: String?,
    timeZone: TimeZone? = nil
  ) {
    self.id = id
    self.title = title
    self.calendarID = calendarID
    self.start = start
    self.end = end
    self.location = location
    self.timeZone = timeZone
  }

  func dayCalendar(_ base: Calendar = .autoupdatingCurrent) -> Calendar {
    guard let timeZone else { return base }
    var calendar = base
    calendar.timeZone = timeZone
    return calendar
  }

  /// The helper spells an all-day item either as a single midnight instant or as midnight through
  /// midnight on a later day, so both shapes count. A start that is not midnight is a timed item
  /// even when the helper sends no end.
  var isAllDay: Bool { isAllDay(in: .autoupdatingCurrent) }

  func isAllDay(in base: Calendar) -> Bool {
    let calendar = dayCalendar(base)
    guard let start, calendar.startOfDay(for: start) == start else { return false }
    guard let end else { return true }
    return end == start || calendar.startOfDay(for: end) == end
  }

  /// Half-open: whole days for an all-day item, the helper's own range for a timed one, the
  /// starting instant when there is no end.
  func span(in base: Calendar = .autoupdatingCurrent) -> Range<Date>? {
    guard let start else { return nil }
    if let end, end > start { return start..<end }
    if isAllDay(in: base) {
      let calendar = dayCalendar(base)
      let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
      return start..<max(next ?? start, start.addingTimeInterval(1))
    }
    return start..<start.addingTimeInterval(1)
  }

  /// An item starting exactly at midnight belongs to the day that begins, never to the one that
  /// ends; an overnight or multi-day item belongs to every day it runs through.
  func overlaps(_ window: DateInterval, calendar: Calendar = .autoupdatingCurrent) -> Bool {
    guard let start else { return false }
    guard isAllDay(in: calendar) else {
      guard let span = span(in: calendar) else { return false }
      return span.lowerBound < window.end && span.upperBound > window.start
    }
    let itemCalendar = dayCalendar(calendar)
    let firstDay = Self.dayNumber(start, itemCalendar)
    let lastDay =
      (end?.addingTimeInterval(-1)).flatMap { last in
        last > start ? Self.dayNumber(last, itemCalendar) : nil
      } ?? firstDay
    let windowFirst = Self.dayNumber(window.start, calendar)
    let windowLast = Self.dayNumber(window.end.addingTimeInterval(-1), calendar)
    return firstDay <= windowLast && lastDay >= windowFirst
  }

  /// Whether the item sits on the viewer's own day: an all-day item by the day Fantastical named,
  /// a timed one by the instants it occupies.
  func falls(on date: Date, viewer: Calendar) -> Bool {
    guard let start else { return false }
    guard isAllDay(in: viewer) else { return viewer.isDate(start, inSameDayAs: date) }
    return Self.dayNumber(start, dayCalendar(viewer)) == Self.dayNumber(date, viewer)
  }

  /// A comparable day label, so an all-day item is filed by the day the helper gave it rather
  /// than by the instants that day happens to occupy in the viewer's zone.
  private static func dayNumber(_ date: Date, _ calendar: Calendar) -> Int {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
  }
}

/// Builds the concrete `when` ranges the helper insists on ("this week" is rejected).
enum FantasticalWhen {
  static func range(from start: Date, to end: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    "\(format(start, calendar: calendar)) to \(format(end, calendar: calendar))"
  }

  static func day(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    format(date, calendar: calendar)
  }

  private static func format(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMMM d, yyyy"
    return formatter.string(from: date)
  }
}

enum FantasticalAgendaFormat {
  static func detail(
    _ item: FantasticalAgendaItem, calendarTitle: String?, now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    var parts: [String] = []
    if let start = item.start {
      parts.append(timeDescription(item, start: start, now: now, calendar: calendar))
    } else {
      parts.append("No date")
    }
    if let calendarTitle, !calendarTitle.isEmpty { parts.append(calendarTitle) }
    if let location = item.location { parts.append(location) }
    return parts.joined(separator: " · ")
  }

  private static func timeDescription(
    _ item: FantasticalAgendaItem, start: Date, now: Date, calendar: Calendar
  ) -> String {
    let isAllDay = item.isAllDay(in: calendar)
    let dayMath = isAllDay ? item.dayCalendar(calendar) : calendar
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = dayMath
    dayFormatter.timeZone = dayMath.timeZone
    dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = calendar.timeZone
    timeFormatter.timeStyle = .short
    timeFormatter.dateStyle = .none

    let day = item.falls(on: now, viewer: calendar) ? "Today" : dayFormatter.string(from: start)
    if isAllDay {
      if let end = item.end, end > start,
        let lastDay = dayMath.date(byAdding: .second, value: -1, to: end),
        !dayMath.isDate(lastDay, inSameDayAs: start)
      {
        return "\(day) to \(dayFormatter.string(from: lastDay)), all day"
      }
      return "\(day), all day"
    }
    var text = "\(day), \(timeFormatter.string(from: start))"
    if let end = item.end, end > start {
      text += " to \(timeFormatter.string(from: end))"
    }
    return text
  }
}
