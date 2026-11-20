import AppKit
import Foundation
import TunaKit

/// What a NotePlan link points at: a note or folder by its path, or a calendar note by its period.
enum NotePlanReference: Equatable, Sendable {
  case file(String)
  case calendar(NotePlanCalendarPeriod)
}

/// Calendar notes whose date string does not depend on the user's NotePlan settings. Weekly notes
/// are left out: their numbering follows NotePlan's first-day-of-week setting.
enum NotePlanCalendarPeriod: String, CaseIterable, Sendable {
  case today
  case tomorrow
  case yesterday
  case thisMonth
  case thisQuarter
  case thisYear

  var title: String {
    switch self {
    case .today: return "Today"
    case .tomorrow: return "Tomorrow"
    case .yesterday: return "Yesterday"
    case .thisMonth: return "This Month"
    case .thisQuarter: return "This Quarter"
    case .thisYear: return "This Year"
    }
  }

  var detail: String {
    switch self {
    case .today: return "Today's daily note"
    case .tomorrow: return "Tomorrow's daily note"
    case .yesterday: return "Yesterday's daily note"
    case .thisMonth: return "This month's note"
    case .thisQuarter: return "This quarter's note"
    case .thisYear: return "This year's note"
    }
  }

  var symbolName: String {
    switch self {
    case .today: return "sun.max"
    case .tomorrow: return "sunrise"
    case .yesterday: return "moon"
    case .thisMonth: return "calendar"
    case .thisQuarter: return "chart.pie"
    case .thisYear: return "globe"
    }
  }

  /// The `noteDate` value NotePlan resolves when the link opens, so "Today" stays today.
  func noteDate(now: Date = Date(), calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month], from: now)
    let year = components.year ?? 0
    let month = components.month ?? 1
    switch self {
    case .today, .tomorrow, .yesterday:
      return rawValue
    case .thisMonth:
      return String(format: "%04d-%02d", year, month)
    case .thisQuarter:
      return String(format: "%04d-Q%d", year, (month - 1) / 3 + 1)
    case .thisYear:
      return String(format: "%04d", year)
    }
  }
}

/// Anything the extension can open in NotePlan.
protocol NotePlanOpenable: CatalogItem {
  var reference: NotePlanReference { get }
}

final class NotePlanNoteItem: CatalogItem, NotePlanOpenable, CopyRepresentationProviding,
  TextValueProviding, TimestampedCatalogItem, @unchecked Sendable
{
  let filename: String
  let folderName: String
  let modifiedAt: Date?

  var reference: NotePlanReference { .file(filename) }
  var capturedAtDate: Date { modifiedAt ?? .distantPast }
  var textValue: String { title }

  var copyRepresentation: String? {
    NotePlanURLBuilder.openURL(for: reference)?.absoluteString
  }

  init(record: NotePlanNoteRecord) {
    filename = record.filename
    folderName = NotePlanPaths.displayFolder(record.folder)
    modifiedAt = record.modifiedAt
    super.init(
      id: "noteplan.note.\(record.filename)",
      title: NotePlanPaths.displayTitle(record.title, filename: record.filename),
      type: .entity)
    typeID = .notePlanNote
  }

  override var searchText: String {
    folderName.isEmpty ? title : "\(title) \(folderName)"
  }

  override var detail: String? {
    var parts: [String] = []
    if !folderName.isEmpty {
      parts.append(folderName)
    }
    if let modifiedAt {
      parts.append(modifiedAt.formatted(.relative(presentation: .named)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " • ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("doc.text", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("doc.text", tintColor: .secondaryLabelColor)
  }
}

final class NotePlanFolderItem: CatalogItem, NotePlanOpenable, @unchecked Sendable {
  let filename: String
  private let parentName: String

  var reference: NotePlanReference { .file(filename) }

  init(record: NotePlanFolderRecord) {
    filename = record.filename
    parentName = NotePlanPaths.displayFolder(
      (record.filename as NSString).deletingLastPathComponent)
    super.init(
      id: "noteplan.folder.\(record.filename)",
      title: NotePlanPaths.displayTitle(record.title, filename: record.filename),
      type: .entity)
    typeID = .notePlanFolder
  }

  override var detail: String? {
    parentName.isEmpty ? "Folder" : "Folder in \(parentName)"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("folder", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("folder", tintColor: .secondaryLabelColor)
  }
}

final class NotePlanCalendarItem: CatalogItem, NotePlanOpenable, CopyRepresentationProviding,
  @unchecked Sendable
{
  let period: NotePlanCalendarPeriod

  var reference: NotePlanReference { .calendar(period) }

  var copyRepresentation: String? {
    NotePlanURLBuilder.openURL(for: reference)?.absoluteString
  }

  init(period: NotePlanCalendarPeriod) {
    self.period = period
    super.init(id: "noteplan.calendar.\(period.rawValue)", title: period.title, type: .entity)
    typeID = .notePlanNote
  }

  override var searchText: String { "\(title) NotePlan" }

  override var detail: String? { period.detail }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol(period.symbolName)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol(period.symbolName)
  }
}

enum NotePlanPaths {
  /// Notes in a shared space live under `%%NotePlanCloud%%/<space id>/…`; that prefix is storage
  /// plumbing, not a folder the user knows.
  static let spacePrefix = "%%NotePlanCloud%%"

  static func displayFolder(_ folder: String) -> String {
    var components = folder.split(separator: "/").map(String.init)
    if components.first == spacePrefix {
      components.removeFirst(min(2, components.count))
      components.insert("Space", at: 0)
    }
    return components.joined(separator: " › ")
  }

  static func displayTitle(_ title: String, filename: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let name = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
    return name.isEmpty ? "Untitled" : name
  }
}

extension TypeID {
  static let notePlanNote = TypeID("com.tuna.type.noteplan-note")
  static let notePlanFolder = TypeID("com.tuna.type.noteplan-folder")
}
