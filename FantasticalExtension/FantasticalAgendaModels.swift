import Foundation

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

enum FantasticalAgendaParser {
  static let noResultsMarker = "No results found."

  static func calendars(from text: String) throws -> [FantasticalCalendar] {
    guard let array = try json(text) as? [[String: Any]] else { return [] }
    return array.compactMap { entry in
      guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
      return FantasticalCalendar(
        id: id,
        title: title,
        isWritable: entry["isWritable"] as? Bool ?? false,
        supportsEvents: entry["supportsEvents"] as? Bool ?? false,
        supportsTasks: entry["supportsTasks"] as? Bool ?? false,
        sourceName: entry["sourceName"] as? String ?? ""
      )
    }
  }

  static func items(from text: String) throws -> [FantasticalAgendaItem] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == noResultsMarker { return [] }
    let object = try json(trimmed)
    let envelope = object as? [String: Any]
    let helperZone = (envelope?["timezone"] as? String).flatMap(TimeZone.init(identifier:))
    let array = envelope?["items"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
    return array.compactMap { entry in
      guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
      return FantasticalAgendaItem(
        id: id,
        title: title,
        calendarID: entry["calendarId"] as? String ?? "",
        start: date(entry["startDate"], zone: helperZone),
        end: date(entry["endDate"], zone: helperZone),
        location: (entry["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        timeZone: preferredZone(
          stamped: zone(entry["startDate"]), helper: helperZone,
          at: date(entry["startDate"], zone: helperZone))
      )
    }
  }

  private static func json(_ text: String) throws -> Any {
    guard let data = text.data(using: .utf8) else { throw FantasticalMCPError.invalidResponse }
    do {
      return try JSONSerialization.jsonObject(with: data)
    } catch {
      throw FantasticalMCPError.invalidResponse
    }
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let isoFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func date(_ value: Any?, zone: TimeZone?) -> Date? {
    guard let string = value as? String else { return nil }
    if let date = isoFormatter.date(from: string) { return date }
    if let date = isoFractionalFormatter.date(from: string) { return date }
    return floating(string, zone: zone)
  }

  /// A timestamp carrying no offset is a floating local time, which the helper means in its own
  /// zone, so it is read there rather than dropped.
  private static func floating(_ string: String, zone: TimeZone?) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone ?? .autoupdatingCurrent
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: string) { return date }
    }
    return nil
  }

  /// The offset stamped on the date wins, because it is what the item was written with. The
  /// envelope's named zone is taken only when it agrees, since only a named zone knows DST.
  private static func preferredZone(stamped: TimeZone?, helper: TimeZone?, at date: Date?) -> TimeZone? {
    guard let stamped else { return helper }
    guard let helper, let date,
      helper.secondsFromGMT(for: date) == stamped.secondsFromGMT(for: date)
    else { return stamped }
    return helper
  }

  /// `ISO8601DateFormatter` drops the offset, so it is read back off the string when the
  /// envelope names no zone.
  private static func zone(_ value: Any?) -> TimeZone? {
    guard let string = value as? String else { return nil }
    if string.hasSuffix("Z") || string.hasSuffix("z") { return TimeZone(secondsFromGMT: 0) }
    guard let range = string.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) else {
      return nil
    }
    let offset = string[range]
    let digits = offset.filter(\.isNumber)
    guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2))
    else { return nil }
    let sign = offset.hasPrefix("-") ? -1 : 1
    return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
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
