import AppKit
import Foundation
import TunaKit

struct NotePlanNoteRecord: Codable, Equatable, Sendable {
  let title: String
  let filename: String
  let folder: String
  let modifiedAt: Date?
}

struct NotePlanFolderRecord: Codable, Equatable, Sendable {
  let title: String
  let filename: String
}

struct NotePlanSnapshot: Codable, Equatable, Sendable {
  var notes: [NotePlanNoteRecord]
  var folders: [NotePlanFolderRecord]

  static let empty = NotePlanSnapshot(notes: [], folders: [])

  var isEmpty: Bool { notes.isEmpty && folders.isEmpty }
}

enum NotePlanProviderError: LocalizedError, Equatable {
  case automationDenied
  case failed(String)

  var title: String {
    switch self {
    case .automationDenied: return "Allow Tuna to control NotePlan"
    case .failed: return "Couldn’t read NotePlan notes"
    }
  }

  var errorDescription: String? {
    switch self {
    case .automationDenied:
      return "Turn on NotePlan for Tuna under Privacy & Security › Automation."
    case .failed(let message):
      return message
    }
  }
}

/// The only boundary to NotePlan's data. Reads go through NotePlan's own Apple Events commands, so
/// the extension never opens NotePlan's storage (local, iCloud, or a shared space) itself. NotePlan
/// has to be running to answer; the last answer is cached so notes stay searchable while it is not.
enum NotePlanProvider {
  /// App Store / direct, and Setapp.
  static let bundleIdentifiers = ["co.noteplan.NotePlan3", "co.noteplan.NotePlan-setapp"]
  static let recordSeparator = "\u{1E}"

  // Injectable for tests.
  nonisolated(unsafe) static var runOverride: (@Sendable (String) throws -> String)?
  nonisolated(unsafe) static var runningBundleIdentifierOverride: (@Sendable () -> String?)?
  nonisolated(unsafe) static var cacheURLOverride: URL?

  static func runningBundleIdentifier() -> String? {
    if let runningBundleIdentifierOverride {
      return runningBundleIdentifierOverride()
    }
    return bundleIdentifiers.first {
      !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }
  }

  static func isNotePlanBundleIdentifier(_ identifier: String?) -> Bool {
    guard let identifier else { return false }
    return bundleIdentifiers.contains(identifier)
  }

  // MARK: Reads

  /// Asks the running NotePlan for its notes and folders. Returns the cached snapshot, without
  /// launching NotePlan, when it is not running.
  static func loadSnapshot() -> Result<NotePlanSnapshot, NotePlanProviderError> {
    guard let bundleIdentifier = runningBundleIdentifier() else {
      return .success(cachedSnapshot() ?? .empty)
    }

    do {
      let output = try run(script(bundleIdentifier: bundleIdentifier))
      let snapshot = try parse(output)
      // NotePlan answers with empty lists while it is still loading or has no license; a previous
      // good answer is more useful than that.
      if snapshot.isEmpty, let cached = cachedSnapshot(), !cached.isEmpty {
        return .success(cached)
      }
      storeSnapshot(snapshot)
      return .success(snapshot)
    } catch let error as NotePlanProviderError {
      if error != .automationDenied, let cached = cachedSnapshot(), !cached.isEmpty {
        return .success(cached)
      }
      return .failure(error)
    } catch {
      return .failure(.failed(error.localizedDescription))
    }
  }

  static func script(bundleIdentifier: String) -> String {
    """
    tell application id "\(bundleIdentifier)"
      set noteList to listNotes
      set folderList to listNotes of type "folders"
    end tell
    return noteList & (character id 30) & folderList
    """
  }

  static func parse(_ output: String) throws -> NotePlanSnapshot {
    let parts = output.components(separatedBy: recordSeparator)
    guard parts.count == 2 else {
      throw NotePlanProviderError.failed("NotePlan returned an unexpected answer.")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      let notes = try decoder.decode([NotePlanNoteRecord].self, from: Data(parts[0].utf8))
      let folders = try decoder.decode([NotePlanFolderRecord].self, from: Data(parts[1].utf8))
      return NotePlanSnapshot(
        notes: notes.filter { isVisible($0.filename) },
        folders: folders.filter { isVisible($0.filename) })
    } catch {
      throw NotePlanProviderError.failed("NotePlan returned an unexpected answer.")
    }
  }

  private static func isVisible(_ filename: String) -> Bool {
    !filename.isEmpty && !filename.hasPrefix("@Trash")
  }

  // MARK: Cache

  static var cacheURL: URL? {
    if let cacheURLOverride { return cacheURLOverride }
    let bundle = Bundle(for: NotePlanCatalog.self)
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent(bundle.bundleIdentifier ?? "com.brnbw.tuna.plugins.noteplan")
      .appendingPathComponent("notes.json")
  }

  static func cachedSnapshot() -> NotePlanSnapshot? {
    guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(NotePlanSnapshot.self, from: data)
  }

  static func storeSnapshot(_ snapshot: NotePlanSnapshot) {
    guard let cacheURL else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(snapshot) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }

  // MARK: Execution

  @discardableResult
  static func run(_ source: String) throws -> String {
    if let runOverride {
      return try runOverride(source)
    }

    let result: CLIProcessResult
    do {
      result = try CLIProcessRunner.runSync(
        CLIProcessRequest(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
      )
    } catch {
      throw NotePlanProviderError.failed(error.localizedDescription)
    }

    guard result.succeeded else {
      let message = result.preferredErrorMessage
      if message.contains("-1743") || message.contains("Not authorized") {
        throw NotePlanProviderError.automationDenied
      }
      throw NotePlanProviderError.failed(message)
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Every `noteplan://x-callback-url` link the extension opens.
enum NotePlanURLBuilder {
  enum OpenStyle {
    case mainWindow
    case newWindow
    case splitView
  }

  static func openURL(for reference: NotePlanReference, style: OpenStyle = .mainWindow) -> URL? {
    var items = [referenceItem(reference)]
    switch style {
    case .mainWindow: break
    case .newWindow: items.append(URLQueryItem(name: "subWindow", value: "yes"))
    case .splitView: items.append(URLQueryItem(name: "splitView", value: "yes"))
    }
    return url(action: "openNote", items: items)
  }

  static func addTextURL(text: String, to reference: NotePlanReference) -> URL? {
    guard let text = normalize(text) else { return nil }
    return url(
      action: "addText",
      items: [
        referenceItem(reference),
        item("text", text),
        URLQueryItem(name: "mode", value: "append"),
        URLQueryItem(name: "openNote", value: "no"),
      ])
  }

  static func addNoteURL(text: String) -> URL? {
    guard let text = normalize(text) else { return nil }
    var lines = text.components(separatedBy: .newlines)
    let title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    var items = [item("noteTitle", title), URLQueryItem(name: "openNote", value: "yes")]
    if !body.isEmpty {
      items.append(item("text", body))
    }
    return url(action: "addNote", items: items)
  }

  static func searchURL(query: String) -> URL? {
    guard let query = normalize(query) else { return nil }
    return url(action: "search", items: [item("text", query)])
  }

  /// A task line NotePlan recognizes with every task-marker setting.
  static func taskLine(_ text: String) -> String? {
    guard let text = normalize(text) else { return nil }
    return text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { "- [ ] \($0)" }
      .joined(separator: "\n")
  }

  private static func referenceItem(_ reference: NotePlanReference) -> URLQueryItem {
    switch reference {
    case .file(let filename): return item("fileName", filename)
    case .calendar(let period): return item("noteDate", period.noteDate())
    }
  }

  private static func url(action: String, items: [URLQueryItem]) -> URL? {
    var components = URLComponents()
    components.scheme = "noteplan"
    components.host = "x-callback-url"
    components.path = "/\(action)"
    components.percentEncodedQueryItems = items
    return components.url
  }

  /// Percent-encodes with RFC 3986 unreserved characters only, so "+", "&", and "/" in titles and
  /// filenames survive (`URLQueryItem`'s default encoding leaves "+" ambiguous with a space).
  private static func item(_ name: String, _ value: String) -> URLQueryItem {
    URLQueryItem(
      name: name,
      value: value.addingPercentEncoding(withAllowedCharacters: .notePlanUnreserved) ?? value)
  }

  static func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension CharacterSet {
  fileprivate static let notePlanUnreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
