import Foundation
import TunaKit

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
      logSchemaOnce(entry)
      return FantasticalAgendaItem(
        id: id,
        title: title,
        calendarID: entry["calendarId"] as? String ?? "",
        start: date(entry["startDate"], zone: helperZone),
        end: date(entry["endDate"], zone: helperZone),
        location: (entry["location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        timeZone: preferredZone(
          stamped: zone(entry["startDate"]), helper: helperZone,
          at: date(entry["startDate"], zone: helperZone)),
        isCompleted: completed(entry)
      )
    }
  }

  /// The helper publishes no schema for these rows, so a completion flag is looked for under the
  /// spellings it might use; an absent flag means the task is still open.
  private static func completed(_ entry: [String: Any]) -> Bool {
    for key in ["isCompleted", "completed", "isDone", "done", "isFinished"] {
      if let flag = entry[key] as? Bool { return flag }
      if let number = entry[key] as? NSNumber { return number.boolValue }
      if let text = entry[key] as? String {
        return ["true", "yes", "completed", "done"].contains(text.lowercased())
      }
    }
    for key in ["completionDate", "completedDate", "completedAt"] {
      if let value = entry[key], !(value is NSNull) { return true }
    }
    if let status = entry["status"] as? String {
      return ["completed", "done", "finished"].contains(status.lowercased())
    }
    return false
  }

  private static let schemaLogged = LockedValue<Bool>(false)

  /// Key names only, never a value, so the row schema can be read off the log without putting an
  /// event anywhere near it.
  private static func logSchemaOnce(_ entry: [String: Any]) {
    guard !schemaLogged.value else { return }
    schemaLogged.value = true
    FantasticalMCPClient.log.info(
      "item keys: \(entry.keys.sorted().joined(separator: ","), privacy: .public)")
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
