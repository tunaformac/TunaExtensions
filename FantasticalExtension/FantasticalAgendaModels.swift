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
  var isAllDay: Bool {
    let calendar = dayCalendar()
    guard let start, calendar.startOfDay(for: start) == start else { return false }
    guard let end else { return true }
    return end == start || calendar.startOfDay(for: end) == end
  }

  /// Half-open: whole days for an all-day item, the helper's own range for a timed one, the
  /// starting instant when there is no end.
  var span: Range<Date>? {
    guard let start else { return nil }
    if let end, end > start { return start..<end }
    if isAllDay {
      let calendar = dayCalendar()
      let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
      return start..<max(next ?? start, start.addingTimeInterval(1))
    }
    return start..<start.addingTimeInterval(1)
  }

  /// An item starting exactly at midnight belongs to the day that begins, never to the one that
  /// ends; an overnight or multi-day item belongs to every day it runs through.
  func overlaps(_ window: DateInterval) -> Bool {
    guard let span else { return false }
    return span.lowerBound < window.end && span.upperBound > window.start
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
        start: date(entry["startDate"]),
        end: date(entry["endDate"]),
        location: (entry["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        timeZone: helperZone ?? zone(entry["startDate"])
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

  private static func date(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFormatter.date(from: string)
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
    let dayMath = item.isAllDay ? item.dayCalendar(calendar) : calendar
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = dayMath
    dayFormatter.timeZone = dayMath.timeZone
    dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = calendar.timeZone
    timeFormatter.timeStyle = .short
    timeFormatter.dateStyle = .none

    let day = dayMath.isDate(start, inSameDayAs: now) ? "Today" : dayFormatter.string(from: start)
    if item.isAllDay { return "\(day), all day" }
    var text = "\(day), \(timeFormatter.string(from: start))"
    if let end = item.end, end > start {
      text += " to \(timeFormatter.string(from: end))"
    }
    return text
  }
}
