import Foundation
import TunaKit

enum FantasticalURLBuilder {
  static let mainScheme = "x-fantastical"
  static let miniScheme = "x-fantastical-mini"

  static func parseURL(
    sentence: String, task: Bool, addImmediately: Bool, miniWindow: Bool
  ) -> URL? {
    guard let sentence = normalize(sentence) else { return nil }
    var fields = FantasticalFields()
    fields.sentence = sentence
    return parseURL(
      fields: fields, task: task, addImmediately: addImmediately, miniWindow: miniWindow)
  }

  /// Fantastical 4.2 applies only `sentence`, `notes`, `url`, and `add` from a parse URL while
  /// the preview is shown; the other documented parameters are ignored. Every other field is
  /// therefore written in the parser's own grammar: `todo`, a quoted title, `from … to …`, dates
  /// as text, `all day`, and `/Calendar`.
  static func parseURL(
    fields: FantasticalFields, task: Bool, addImmediately: Bool, miniWindow: Bool
  ) -> URL? {
    guard fields.hasContent else { return nil }
    var queryItems = [
      percentEncodedQueryItem(name: "sentence", value: sentence(for: fields, task: task))
    ]
    for (name, value) in [("url", fields.url), ("notes", fields.notes)] {
      if let value {
        queryItems.append(percentEncodedQueryItem(name: name, value: value))
      }
    }
    if addImmediately {
      queryItems.append(URLQueryItem(name: "add", value: "1"))
    }
    return url(miniWindow: miniWindow, host: "parse", path: "", queryItems: queryItems)
  }

  static func sentence(for fields: FantasticalFields, task: Bool) -> String {
    var parts: [String] = []
    if task { parts.append("todo") }
    if let title = fields.title {
      parts.append("\"" + title.replacingOccurrences(of: "\"", with: "'") + "\"")
    }
    if let sentence = fields.sentence { parts.append(sentence) }
    switch (fields.start, fields.end) {
    case (let start?, let end?): parts.append("from \(start) to \(end)")
    case (let start?, nil): parts.append(start)
    case (nil, let end?): parts.append("until \(end)")
    case (nil, nil): break
    }
    if let due = fields.due { parts.append(due) }
    if fields.allDay { parts.append("all day") }
    if let calendar = fields.calendarName { parts.append("/" + calendar) }
    return parts.joined(separator: " ")
  }

  static func searchURL(query: String, miniWindow: Bool) -> URL? {
    guard let query = normalize(query) else { return nil }
    return url(
      miniWindow: miniWindow, host: "search", path: "",
      queryItems: [percentEncodedQueryItem(name: "s", value: query)])
  }

  static func dateURL(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> URL? {
    url(miniWindow: false, host: "date", path: "/\(format(date, calendar: calendar))", queryItems: [])
  }

  static func showURL(
    for destination: FantasticalDestination,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> URL? {
    switch destination {
    case .today:
      return dateURL(now, calendar: calendar)
    case .tomorrow:
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
      return dateURL(tomorrow, calendar: calendar)
    case .calendar:
      return url(miniWindow: false, host: "show", path: "/calendar", queryItems: [])
    case .miniWindow:
      return url(miniWindow: true, host: "show", path: "/mini", queryItems: [])
    case .calendarSet(let name):
      guard let name = normalize(name) else { return nil }
      return url(
        miniWindow: false, host: "show", path: "/set",
        queryItems: [percentEncodedQueryItem(name: "name", value: name)])
    }
  }

  /// Accepts an ISO `yyyy-MM-dd` string or natural language that the system date detector
  /// recognizes as one whole date ("tomorrow", "next friday", "3 oct").
  static func parseDate(from text: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
    guard let text = normalize(text) else { return nil }
    if let isoDate = isoFormatter(calendar: calendar).date(from: text) {
      return isoDate
    }
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = detector.firstMatch(in: text, options: [], range: range),
      match.range == range
    else { return nil }
    return match.date
  }

  static func format(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    isoFormatter(calendar: calendar).string(from: date)
  }

  static func textValue(for subject: CatalogItem?) -> String? {
    normalize(subject?.textInputValue())
  }

  private static func isoFormatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static func url(
    miniWindow: Bool, host: String, path: String, queryItems: [URLQueryItem]
  ) -> URL? {
    var components = URLComponents()
    components.scheme = miniWindow ? miniScheme : mainScheme
    components.host = host
    components.path = path
    if !queryItems.isEmpty {
      components.percentEncodedQueryItems = queryItems
    }
    return components.url
  }

  /// Percent-encodes with RFC 3986 unreserved characters only, so "+" becomes "%2B" instead of
  /// being read as a space by Fantastical's parser.
  private static func percentEncodedQueryItem(name: String, value: String) -> URLQueryItem {
    URLQueryItem(
      name: name,
      value: value.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? value)
  }

  static func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension CharacterSet {
  fileprivate static let rfc3986Unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

enum FantasticalSettings {
  static let addImmediatelyKey = "AddImmediately"
  static let useMiniWindowKey = "UseMiniWindow"
  static let calendarSetsKey = "CalendarSets"
  static let fieldSeparatorKey = "FieldSeparator"

  static var addImmediately: Bool {
    boolValue(for: addImmediatelyKey, defaultValue: false)
  }

  static var useMiniWindow: Bool {
    boolValue(for: useMiniWindowKey, defaultValue: true)
  }

  static var fieldSeparator: String {
    FantasticalURLBuilder.normalize(
      store.stringValue(for: fieldSeparatorKey, defaultValue: FantasticalFields.defaultSeparator))
      ?? FantasticalFields.defaultSeparator
  }

  static var calendarSetNames: [String] {
    parseCalendarSets(store.stringValue(for: calendarSetsKey, defaultValue: ""))
  }

  static func parseCalendarSets(_ raw: String) -> [String] {
    var seen = Set<String>()
    return raw
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .compactMap { FantasticalURLBuilder.normalize(String($0)) }
      .filter { seen.insert($0).inserted }
  }

  private static func boolValue(for key: String, defaultValue: Bool) -> Bool {
    let raw = store.stringValue(for: key, defaultValue: defaultValue ? "true" : "false")
    return raw.lowercased() == "true"
  }

  private static var store: CatalogSettingStore {
    CatalogSettingStore(catalogIdentifier: extensionIdentifier)
  }

  private static let extensionIdentifier: String = {
    let bundle = Bundle(for: FantasticalActionsCatalog.self)
    return bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaFantastical")
  }()
}
