import Foundation

struct PoofSnippetRecord: Equatable, Sendable {
  let trigger: String
  let replacementTemplate: String
  let details: String?
  let caseSensitive: Bool
  let sourceURL: URL
  let sourceIndex: Int
}

enum PoofConfig {
  static let defaultsDomain = "com.brnbw.Poof"
  static let configDirectoryKey = "Poof.configDirectoryPath"

  static func directory(
    defaults: UserDefaults = UserDefaults(suiteName: defaultsDomain) ?? .standard,
    fileManager: FileManager = .default
  ) -> URL {
    if let path = defaults.string(forKey: configDirectoryKey), !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    return fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Poof", directoryHint: .isDirectory)
  }
}

enum PoofConfigError: LocalizedError {
  case invalidTrigger
  case duplicateTrigger(String)
  case snippetNotFound

  var errorDescription: String? {
    switch self {
    case .invalidTrigger:
      return "Enter a non-empty snippet trigger."
    case .duplicateTrigger(let trigger):
      return "A Poof snippet already uses the trigger \(trigger)."
    case .snippetNotFound:
      return "The snippet changed on disk. Rescan Poof Snippets and try again."
    }
  }
}

struct PoofSnippetFile: Sendable {
  struct Entry: Sendable {
    let record: PoofSnippetRecord
    let tableRange: NSRange
  }

  let url: URL
  let contents: String
  let tableCount: Int
  let entries: [Entry]
}

enum PoofSnippetParser {
  static func loadFiles(in directory: URL, fileManager: FileManager = .default) -> [PoofSnippetFile] {
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    let urls = enumerator.compactMap { element -> URL? in
      guard let url = element as? URL, url.pathExtension.lowercased() == "toml" else { return nil }
      return url
    }.sorted { $0.path < $1.path }

    return urls.compactMap { url in
      guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      return parse(contents, sourceURL: url)
    }
  }

  static func activeRecords(in directory: URL, fileManager: FileManager = .default)
    -> [PoofSnippetRecord]
  {
    var recordsByTrigger: [String: PoofSnippetRecord] = [:]
    for file in loadFiles(in: directory, fileManager: fileManager) {
      for entry in file.entries {
        recordsByTrigger[entry.record.trigger] = entry.record
      }
    }
    return recordsByTrigger.values.sorted {
      if $0.trigger.count == $1.trigger.count { return $0.trigger < $1.trigger }
      return $0.trigger.count > $1.trigger.count
    }
  }

  static func parse(_ contents: String, sourceURL: URL) -> PoofSnippetFile {
    let source = contents as NSString
    let headers = matches(
      pattern: #"(?m)^\s*\[\[(?:snippets|snippet)\]\][^\n]*(?:\n|$)"#,
      in: contents
    )
    let tableRanges: [NSRange]
    if headers.isEmpty {
      tableRanges = [NSRange(location: 0, length: source.length)]
    } else {
      tableRanges = headers.enumerated().map { index, header in
        let end = index + 1 < headers.count ? headers[index + 1].range.location : source.length
        return NSRange(location: header.range.location, length: end - header.range.location)
      }
    }

    let entries = tableRanges.enumerated().compactMap { index, tableRange -> PoofSnippetFile.Entry? in
      guard
        let triggerMatch = assignment(named: "trigger", in: contents, range: tableRange),
        let trigger = decodedString(source.substring(with: triggerMatch.valueRange))?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !trigger.isEmpty,
        let replacementMatch = assignment(named: "replace", in: contents, range: tableRange),
        let replacement = decodedString(source.substring(with: replacementMatch.valueRange))
      else { return nil }

      if let disabled = scalar(named: "disabled", in: contents, range: tableRange),
        disabled.caseInsensitiveCompare("true") == .orderedSame
      {
        return nil
      }

      let details = assignment(named: "description", in: contents, range: tableRange)
        .flatMap { decodedString(source.substring(with: $0.valueRange)) }
      let caseSensitive = scalar(named: "case_sensitive", in: contents, range: tableRange)
        .map { $0.caseInsensitiveCompare("false") != .orderedSame } ?? true
      let record = PoofSnippetRecord(
        trigger: trigger,
        replacementTemplate: replacement,
        details: details,
        caseSensitive: caseSensitive,
        sourceURL: sourceURL,
        sourceIndex: index
      )
      return PoofSnippetFile.Entry(
        record: record,
        tableRange: tableRange
      )
    }

    return PoofSnippetFile(
      url: sourceURL,
      contents: contents,
      tableCount: tableRanges.count,
      entries: entries
    )
  }

  static func encodedString(_ value: String) -> String {
    var encoded = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
    encoded = "\"\(encoded)\""
    return encoded
  }

  private struct AssignmentMatch {
    let valueRange: NSRange
  }

  private static func assignment(named name: String, in contents: String, range: NSRange)
    -> AssignmentMatch?
  {
    let value = #"(?:\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|\"(?:\\.|[^\"\\])*\"|'[^']*')"#
    let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(\(value))"
    guard let match = firstMatch(pattern: pattern, in: contents, range: range), match.numberOfRanges > 1
    else { return nil }
    return AssignmentMatch(valueRange: match.range(at: 1))
  }

  private static func scalar(named name: String, in contents: String, range: NSRange) -> String? {
    let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([^#\\s]+)"
    guard let match = firstMatch(pattern: pattern, in: contents, range: range), match.numberOfRanges > 1
    else { return nil }
    return (contents as NSString).substring(with: match.range(at: 1))
  }

  private static func decodedString(_ raw: String) -> String? {
    if raw.hasPrefix("\"\"\"") && raw.hasSuffix("\"\"\"") {
      return decodeBasic(droppingInitialNewline(from: String(raw.dropFirst(3).dropLast(3))))
    }
    if raw.hasPrefix("'''") && raw.hasSuffix("'''") {
      return droppingInitialNewline(from: String(raw.dropFirst(3).dropLast(3)))
    }
    if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
      return decodeBasic(String(raw.dropFirst().dropLast()))
    }
    if raw.hasPrefix("'") && raw.hasSuffix("'") {
      return String(raw.dropFirst().dropLast())
    }
    return nil
  }

  private static func droppingInitialNewline(from value: String) -> String {
    if value.hasPrefix("\r\n") { return String(value.dropFirst(2)) }
    if value.hasPrefix("\n") { return String(value.dropFirst()) }
    return value
  }

  private static func decodeBasic(_ value: String) -> String {
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
      guard value[index] == "\\" else {
        result.append(value[index])
        index = value.index(after: index)
        continue
      }
      let next = value.index(after: index)
      guard next < value.endIndex else {
        result.append("\\")
        break
      }
      switch value[next] {
      case "n": result.append("\n")
      case "r": result.append("\r")
      case "t": result.append("\t")
      case "\"": result.append("\"")
      case "\\": result.append("\\")
      default:
        result.append("\\")
        result.append(value[next])
      }
      index = value.index(after: next)
    }
    return result
  }

  private static func matches(pattern: String, in contents: String) -> [NSTextCheckingResult] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(
      in: contents,
      range: NSRange(location: 0, length: (contents as NSString).length)
    )
  }

  private static func firstMatch(pattern: String, in contents: String, range: NSRange)
    -> NSTextCheckingResult?
  {
    try? NSRegularExpression(pattern: pattern).firstMatch(in: contents, range: range)
  }
}

struct PoofSnippetStore {
  let directory: URL
  var fileManager: FileManager = .default

  func create(trigger rawTrigger: String, replacement: String) throws -> PoofSnippetRecord {
    let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trigger.isEmpty else { throw PoofConfigError.invalidTrigger }
    try ensureAvailable(trigger: trigger)

    let snippetsDirectory = directory.appending(path: "snippets", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: snippetsDirectory, withIntermediateDirectories: true)
    let baseName = sanitizedFilename(trigger)
    var url = snippetsDirectory.appending(path: "\(baseName).toml")
    var suffix = 2
    while fileManager.fileExists(atPath: url.path) {
      url = snippetsDirectory.appending(path: "\(baseName)-\(suffix).toml")
      suffix += 1
    }
    let contents = """
      [[snippets]]
      trigger = \(PoofSnippetParser.encodedString(trigger))
      replace = \(PoofSnippetParser.encodedString(replacement))
      """ + "\n"
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return PoofSnippetRecord(
      trigger: trigger, replacementTemplate: replacement, details: nil,
      caseSensitive: true, sourceURL: url, sourceIndex: 0)
  }

  func delete(_ record: PoofSnippetRecord) throws {
    let (file, entry) = try currentEntry(for: record)
    if file.tableCount == 1 {
      try fileManager.removeItem(at: record.sourceURL)
      return
    }
    let mutable = NSMutableString(string: file.contents)
    mutable.deleteCharacters(in: entry.tableRange)
    try (mutable as String).write(to: record.sourceURL, atomically: true, encoding: .utf8)
  }

  private func currentEntry(for record: PoofSnippetRecord) throws
    -> (PoofSnippetFile, PoofSnippetFile.Entry)
  {
    guard let contents = try? String(contentsOf: record.sourceURL, encoding: .utf8) else {
      throw PoofConfigError.snippetNotFound
    }
    let file = PoofSnippetParser.parse(contents, sourceURL: record.sourceURL)
    guard let entry = file.entries.first(where: {
      $0.record.sourceIndex == record.sourceIndex
        && $0.record.trigger == record.trigger
        && $0.record.replacementTemplate == record.replacementTemplate
    }) else { throw PoofConfigError.snippetNotFound }
    return (file, entry)
  }

  private func ensureAvailable(trigger: String) throws {
    if PoofSnippetParser.activeRecords(in: directory, fileManager: fileManager)
      .contains(where: { $0.trigger == trigger })
    {
      throw PoofConfigError.duplicateTrigger(trigger)
    }
  }

  private func sanitizedFilename(_ trigger: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let components = trigger.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let name = String(components).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return name.isEmpty ? "snippet" : name
  }
}
