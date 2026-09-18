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

  var isAllDay: Bool {
    guard let start, let end else { return start != nil && end == nil }
    let calendar = Calendar.autoupdatingCurrent
    return start == end && calendar.dateComponents([.hour, .minute], from: start) == DateComponents(hour: 0, minute: 0)
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
    let array = (object as? [String: Any])?["items"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
    return array.compactMap { entry in
      guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
      return FantasticalAgendaItem(
        id: id,
        title: title,
        calendarID: entry["calendarId"] as? String ?? "",
        start: date(entry["startDate"]),
        end: date(entry["endDate"]),
        location: (entry["location"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = calendar.timeZone
    dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = calendar.timeZone
    timeFormatter.timeStyle = .short
    timeFormatter.dateStyle = .none

    let day = calendar.isDate(start, inSameDayAs: now) ? "Today" : dayFormatter.string(from: start)
    if item.isAllDay { return "\(day), all day" }
    var text = "\(day), \(timeFormatter.string(from: start))"
    if let end = item.end, end > start {
      text += " to \(timeFormatter.string(from: end))"
    }
    return text
  }
}
