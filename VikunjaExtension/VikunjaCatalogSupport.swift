import AppKit
import Foundation
import TunaKit

struct VikunjaConnection: Sendable {
  let record: ExtensionConnectionRecord
  let accessToken: String

  var id: String { record.id }
  var displayName: String { record.trimmedDisplayName }
}

/// Posted (object: nil) after this extension writes to Vikunja so catalogs drop cached results.
let VikunjaDataDidChange = Notification.Name("com.crosbyh.tuna.vikunja.dataDidChange")

enum VikunjaCatalogSupport {
  static let providerIdentifier = "vikunja"

  static let connectionDefinition = ExtensionConnectionDefinition(
    providerIdentifier: providerIdentifier,
    providerName: "Vikunja",
    kind: .secret,
    supportsBaseURL: true,
    defaultBaseURL: "",
    baseURLLabel: "Vikunja URL",
    secretLabel: "API Token",
    description:
      "Enter the HTTPS URL of your Vikunja server (for example https://tasks.example.com) and an API token created in Vikunja under Settings → API Tokens with read and write access to Projects and Tasks.",
    connectButtonLabel: "Add Connection"
  )

  static func connections() -> [VikunjaConnection] {
    let store = ExtensionConnectionStore(
      extensionIdentifier: VikunjaSettings.extensionIdentifier,
      providerIdentifier: providerIdentifier
    )
    return store.orderedRecords().compactMap { record in
      guard
        let accessToken = store.accessToken(for: record)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !accessToken.isEmpty
      else { return nil }
      return VikunjaConnection(record: record, accessToken: accessToken)
    }
  }

  /// The connection that receives tasks added without an explicit project.
  static func defaultConnection() -> VikunjaConnection? {
    let store = ExtensionConnectionStore(
      extensionIdentifier: VikunjaSettings.extensionIdentifier,
      providerIdentifier: providerIdentifier
    )
    let all = connections()
    if let defaultID = store.defaultRecordID(), let match = all.first(where: { $0.id == defaultID }) {
      return match
    }
    return all.first
  }

  static func connection(id: String) -> VikunjaConnection? {
    connections().first { $0.id == id }
  }

  // MARK: Status items

  static func authRequiredItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Connect Vikunja",
      message: "Add a Vikunja connection in extension settings to load tasks and projects.",
      symbolName: "person.crop.circle.badge.exclamationmark",
      tintColor: .systemOrange
    )
  }

  static func loadingItem(_ subject: String = "Vikunja") -> CatalogLoadingItem {
    CatalogLoadingItem(title: "Loading \(subject)", message: "Fetching from Vikunja.")
  }

  static func emptyItem(title: String, message: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: title, message: message, symbolName: "tray", tintColor: .secondaryLabelColor)
  }

  /// With several connections, pass the failing one so its name prefixes the title.
  static func errorItem(_ error: Error, connection: VikunjaConnection? = nil) -> CatalogMessageItem {
    let title = (error as? VikunjaAPIError)?.title ?? "Vikunja request failed"
    return CatalogMessageItem(
      title: connection.map { "\($0.displayName): \(title)" } ?? title,
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  /// Shown after a task listing that stopped at the page limit.
  static func truncatedItem(shown: Int, searching: Bool) -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Showing the first \(shown) tasks",
      message: searching
        ? "Refine the search to find tasks past the first \(shown)."
        : "Type to search, or open Vikunja, to reach tasks past the first \(shown).",
      symbolName: "ellipsis.circle",
      tintColor: .secondaryLabelColor
    )
  }

  static func postScanFinished(identifier: String) {
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  static func postDataDidChange() {
    NotificationCenter.default.post(name: VikunjaDataDidChange, object: nil)
  }

  // MARK: Multi-connection helpers

  struct ConnectionResult<Payload: Sendable>: Sendable {
    let offset: Int
    let connection: VikunjaConnection
    let payload: Result<Payload, Error>
  }

  /// Runs `operation` for every connection concurrently. Failures are captured per connection so
  /// one unreachable or unauthorized server doesn't hide the others. Results keep connection order.
  static func loadPerConnection<Payload: Sendable>(
    _ connections: [VikunjaConnection],
    operation: @escaping @Sendable (VikunjaConnection) async throws -> Payload
  ) async -> [ConnectionResult<Payload>] {
    await withTaskGroup(of: ConnectionResult<Payload>.self) { group in
      for (offset, connection) in connections.enumerated() {
        group.addTask {
          do {
            return ConnectionResult(
              offset: offset, connection: connection, payload: .success(try await operation(connection)))
          } catch {
            return ConnectionResult(offset: offset, connection: connection, payload: .failure(error))
          }
        }
      }
      var results: [ConnectionResult<Payload>] = []
      for await result in group { results.append(result) }
      return results.sorted { $0.offset < $1.offset }
    }
  }

  // MARK: Project resolution

  /// Matches the default-project setting by numeric id, then case-insensitive title, then Inbox,
  /// then the first project.
  static func resolveDefaultProject(
    _ projects: [VikunjaProject], preference: String
  ) -> VikunjaProject? {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = Int(trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed),
      let match = projects.first(where: { $0.id == id })
    {
      return match
    }
    if let match = projects.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return match
    }
    if let match = projects.first(where: { $0.title.caseInsensitiveCompare("Inbox") == .orderedSame }) {
      return match
    }
    return projects.first
  }

  /// "Home › Home assistant" for nested projects.
  static func projectPath(_ project: VikunjaProject, in projects: [VikunjaProject]) -> String {
    var parts = [project.title]
    var parentID = project.parentProjectID
    var guardCount = 0
    while parentID > 0, guardCount < 10, let parent = projects.first(where: { $0.id == parentID }) {
      parts.insert(parent.title, at: 0)
      parentID = parent.parentProjectID
      guardCount += 1
    }
    return parts.joined(separator: " › ")
  }

  // MARK: Formatting

  static func taskDetail(
    _ task: VikunjaTask,
    projectTitle: String?,
    connection: VikunjaConnection?,
    totalConnections: Int,
    now: Date = Date()
  ) -> String {
    var parts: [String] = []
    if totalConnections > 1, let connection {
      parts.append(connection.displayName)
    }
    if let projectTitle, !projectTitle.isEmpty {
      parts.append(projectTitle)
    }
    if let dueDate = task.dueDate {
      parts.append(dueDescription(dueDate, now: now))
    }
    if let priority = task.priorityName {
      parts.append(priority)
    }
    if !task.labels.isEmpty {
      parts.append(task.labels.map(\.title).joined(separator: " "))
    }
    if task.done {
      parts.append("Done")
    }
    return parts.joined(separator: " · ")
  }

  static func dueDescription(_ dueDate: Date, now: Date = Date()) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDate(dueDate, inSameDayAs: now) {
      return "Due today"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
      calendar.isDate(dueDate, inSameDayAs: tomorrow)
    {
      return "Due tomorrow"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(dueDate, inSameDayAs: yesterday)
    {
      return "Due yesterday"
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    formatter.doesRelativeDateFormatting = false
    let prefix = dueDate < now ? "Overdue" : "Due"
    return "\(prefix) \(formatter.string(from: dueDate))"
  }

  enum DueBucket: Int, CaseIterable, Sendable {
    case overdue
    case today
    case upcoming
    case later
    case undated

    var title: String {
      switch self {
      case .overdue: return "Overdue"
      case .today: return "Today"
      case .upcoming: return "Next 7 Days"
      case .later: return "Later"
      case .undated: return "No Due Date"
      }
    }

    var symbolName: String {
      switch self {
      case .overdue: return "exclamationmark.circle"
      case .today: return "sun.max"
      case .upcoming: return "calendar"
      case .later: return "clock"
      case .undated: return "tray"
      }
    }

    var iconColor: CatalogIconColor {
      switch self {
      case .overdue: return .red
      case .today: return .orange
      case .upcoming: return .blue
      case .later: return .gray
      case .undated: return .gray
      }
    }
  }

  static func dueBucket(for task: VikunjaTask, now: Date = Date()) -> DueBucket {
    guard let dueDate = task.dueDate else { return .undated }
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDate(dueDate, inSameDayAs: now) { return .today }
    if dueDate < now { return .overdue }
    if let weekOut = calendar.date(byAdding: .day, value: 7, to: now), dueDate <= weekOut {
      return .upcoming
    }
    return .later
  }

  /// Dated tasks first (soonest first), then undated by title.
  static func sortedByDue(_ tasks: [VikunjaTask]) -> [VikunjaTask] {
    tasks.sorted { lhs, rhs in
      switch (lhs.dueDate, rhs.dueDate) {
      case (let l?, let r?) where l != r:
        return l < r
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }
  }

  /// Maps a Vikunja hex color to the nearest Tuna catalog icon tint.
  static func iconColor(forHex hex: String) -> CatalogIconColor {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return .blue }
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC
    guard delta > 0.08, maxC > 0.15 else { return .gray }

    var hue: Double
    if maxC == r {
      hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maxC == g {
      hue = (b - r) / delta + 2
    } else {
      hue = (r - g) / delta + 4
    }
    hue *= 60
    if hue < 0 { hue += 360 }

    switch hue {
    case ..<15: return .red
    case ..<40: return .orange
    case ..<70: return .yellow
    case ..<160: return .green
    case ..<185: return .mint
    case ..<200: return .teal
    case ..<250: return .blue
    case ..<275: return .indigo
    case ..<300: return .purple
    case ..<345: return .pink
    default: return .red
    }
  }
}

// MARK: - Sorting

/// Catalog sort options shared by the Vikunja catalogs: sections keep their declared order,
/// tasks sort by due date (undated last), everything else by title.
enum VikunjaSort {
  static let dueOptionID = "vikunja.due"

  /// Tuna's time sort shows newest `capturedAtDate` first, so tasks carry a mirrored due date:
  /// the sooner a task is due, the newer its timestamp. Undated tasks sort last.
  private static let mirrorPoint = Date(timeIntervalSinceReferenceDate: 1_500_000_000)  // ~2048

  static let sectionScoreBase: Double = 1_000_000_000_000

  /// Higher scores sort first. Dated tasks score by how soon they are due (sooner is higher);
  /// undated tasks fall below every dated one and order by priority.
  static func score(forDueDate dueDate: Date?, priority: Int) -> Double {
    guard let dueDate else { return Double(max(0, min(priority, 5))) }
    let mirrored = 2 * mirrorPoint.timeIntervalSinceReferenceDate - dueDate.timeIntervalSinceReferenceDate
    return 1_000 + max(0, mirrored)
  }

  static func timestamp(forDueDate dueDate: Date?) -> Date {
    guard let dueDate else { return .distantPast }
    return Date(timeIntervalSinceReferenceDate: 2 * mirrorPoint.timeIntervalSinceReferenceDate - dueDate.timeIntervalSinceReferenceDate)
  }

  static let options: [CatalogSortOption] = [
    CatalogSortOption(id: dueOptionID, title: "Due Date", detail: "Soonest first", comparator: compareByDue),
    .nameAscending,
    .nameDescending,
  ]

  static func compareByDue(_ lhs: CatalogItem, _ rhs: CatalogItem) -> Bool {
    switch (lhs, rhs) {
    case (let l as VikunjaSectionItem, let r as VikunjaSectionItem):
      if l.sortOrder != r.sortOrder { return l.sortOrder < r.sortOrder }
    case (is VikunjaSectionItem, _):
      return true
    case (_, is VikunjaSectionItem):
      return false
    case (let l as VikunjaTaskItem, let r as VikunjaTaskItem):
      return VikunjaCatalogSupport.sortedByDue([l.task, r.task]).first?.id == l.task.id
    case (is VikunjaTaskItem, _):
      return true
    case (_, is VikunjaTaskItem):
      return false
    default:
      break
    }
    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
  }
}
