import Foundation

/// Structured values for Fantastical's `parse` URL. Built either from typed text with
/// inline fields ("Dentist tomorrow 15h -- notes: bring card -- cal: Perso") or from a
/// link item whose title becomes the sentence and whose address fills `url`.
struct FantasticalFields: Equatable, Sendable {
  var sentence: String?
  var title: String?
  var start: String?
  var end: String?
  var due: String?
  var allDay = false
  var calendarName: String?
  var url: String?
  var notes: String?

  static let defaultSeparator = "--"
  static let allDayKeys: Set<String> = ["allday", "all-day", "all day"]
  static let falseValues: Set<String> = ["0", "false", "no", "off"]

  enum ParseError: Error, Equatable {
    case empty
    case unknownField(String)
    case missingValue(String)

    var message: String {
      switch self {
      case .empty: return "Nothing to add"
      case .unknownField(let name): return "Unknown field: \(name)"
      case .missingValue(let name): return "Missing value for \(name)"
      }
    }
  }

  var hasContent: Bool { sentence != nil || title != nil }

  static func parse(
    _ text: String, separator: String = defaultSeparator
  ) -> Result<FantasticalFields, ParseError> {
    var segments = split(text, separator: separator)
    guard !segments.isEmpty else { return .failure(.empty) }

    var fields = FantasticalFields()
    fields.sentence = normalize(segments.removeFirst())

    for segment in segments {
      guard let colon = segment.firstIndex(of: ":") else {
        guard let flag = normalize(segment)?.lowercased() else { continue }
        guard allDayKeys.contains(flag) else { return .failure(.unknownField(flag)) }
        fields.allDay = true
        continue
      }
      let key = segment[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = normalize(String(segment[segment.index(after: colon)...]))
      if allDayKeys.contains(key) {
        fields.allDay = value.map { !falseValues.contains($0.lowercased()) } ?? true
        continue
      }
      guard let value else { return .failure(.missingValue(key)) }
      switch key {
      case "title": fields.title = value
      case "start", "from": fields.start = value
      case "end", "to": fields.end = value
      case "due": fields.due = value
      case "cal", "calendar": fields.calendarName = value
      case "url", "link": fields.url = value
      case "note", "notes": fields.notes = value
      default: return .failure(.unknownField(key))
      }
    }

    guard fields.hasContent else { return .failure(.empty) }
    return .success(fields)
  }

  /// Splits on the separator only where it stands alone between whitespace (or at the
  /// text boundaries), so "https://x.com/a--b" survives a "--" separator.
  private static func split(_ text: String, separator: String) -> [String] {
    guard let separator = normalize(separator) else { return [text] }
    let alternatives = separatorVariants(separator)
      .map(NSRegularExpression.escapedPattern(for:))
      .joined(separator: "|")
    guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s+)(?:\(alternatives))(?:\\s+|$)")
    else { return [text] }
    let nsText = text as NSString
    var pieces: [String] = []
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      pieces.append(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
      cursor = match.range.location + match.range.length
    }
    pieces.append(nsText.substring(from: cursor))
    return pieces
  }

  /// macOS smart dashes rewrite "--" as an em dash while typing, so a double-hyphen separator
  /// also matches the em and en dashes it turns into.
  static func separatorVariants(_ separator: String) -> [String] {
    separator == "--" ? ["--", "\u{2014}", "\u{2013}"] : [separator]
  }

  private static func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
