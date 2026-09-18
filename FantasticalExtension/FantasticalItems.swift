import AppKit
import Foundation
import TunaKit

enum FantasticalDestination: Equatable, Sendable {
  case today
  case tomorrow
  case calendar
  case miniWindow
  case calendarSet(String)

  var identifier: String {
    switch self {
    case .today: return "fantastical.view.today"
    case .tomorrow: return "fantastical.view.tomorrow"
    case .calendar: return "fantastical.view.calendar"
    case .miniWindow: return "fantastical.view.mini"
    case .calendarSet(let name): return "fantastical.set.\(name)"
    }
  }

  var title: String {
    switch self {
    case .today: return "Today"
    case .tomorrow: return "Tomorrow"
    case .calendar: return "Calendar"
    case .miniWindow: return "Mini Window"
    case .calendarSet(let name): return "Set: \(name)"
    }
  }

  var detail: String {
    switch self {
    case .today: return "Reveal today in Fantastical"
    case .tomorrow: return "Reveal tomorrow in Fantastical"
    case .calendar: return "Open the main Fantastical window"
    case .miniWindow: return "Open the menu bar Mini Window"
    case .calendarSet: return "Switch Fantastical to this calendar set"
    }
  }

  var symbolName: String {
    switch self {
    case .today: return "sun.max"
    case .tomorrow: return "calendar.badge.clock"
    case .calendar: return "calendar"
    case .miniWindow: return "menubar.rectangle"
    case .calendarSet: return "square.stack.3d.up"
    }
  }
}

final class FantasticalDestinationItem: CatalogItem, CopyRepresentationProviding,
  TextValueProviding, @unchecked Sendable
{
  let destination: FantasticalDestination

  init(destination: FantasticalDestination) {
    self.destination = destination
    super.init(id: destination.identifier, title: destination.title, type: .entity)
    typeID = .fantasticalDestination
  }

  var textValue: String {
    FantasticalURLBuilder.showURL(for: destination)?.absoluteString ?? id
  }

  var copyRepresentation: String? { textValue }

  override var searchText: String {
    "Fantastical \(destination.title)"
  }

  override var detail: String? { destination.detail }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol(destination.symbolName)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

/// "New Event" and "New Task" search entries; the typed text is the action's target. With a
/// calendar the entry adds into that calendar instead of Fantastical's default.
class FantasticalNewItemEntry: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  let isTask: Bool
  let calendar: FantasticalCalendar?

  init(task: Bool, calendar: FantasticalCalendar? = nil) {
    isTask = task
    self.calendar = calendar
    let kind = task ? "New Task" : "New Event"
    let base = task ? "fantastical.new-task" : "fantastical.new-event"
    super.init(
      id: calendar.map { "\(base).\($0.id)" } ?? base,
      title: calendar.map { "\(kind) in \($0.title)" } ?? kind, path: nil)
    typeID = .searchCatalogEntry
  }

  override var searchText: String { "Fantastical \(title)" }

  override var detail: String? {
    if let calendar { return calendar.sourceName }
    return isTask
      ? "Add a task to Fantastical from typed text; browse to pick the list"
      : "Add an event to Fantastical from typed text; browse to pick the calendar"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(isTask ? "checkmark.circle" : "calendar.badge.plus")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    catalogIdentifier == FantasticalIdentifiers.actionCatalog
      && action.id == FantasticalIdentifiers.addTypedAction
  }
}

/// The two searchable roots; browsing one lists the writable calendars of its kind.
final class FantasticalNewItemRoot: FantasticalNewItemEntry, CatalogHierarchyNode, @unchecked Sendable {
  func hierarchyChildren() -> [CatalogItem] {
    let matching = FantasticalAgendaSupport.knownCalendars.readValue { $0 }
      .filter { $0.isWritable && (isTask ? $0.supportsTasks : $0.supportsEvents) }
    guard !matching.isEmpty else {
      Task { _ = try? await FantasticalAgendaSupport.calendars() }
      return [
        FantasticalAgendaSupport.messageItem(
          title: "Calendars Not Loaded Yet", message: "Try again in a moment.",
          symbolName: "arrow.clockwise", tint: .secondaryLabelColor)
      ]
    }
    return matching.map { FantasticalNewItemEntry(task: isTask, calendar: $0) }
  }
}

extension TypeID {
  static let fantasticalDestination = TypeID("com.tuna.type.fantastical-destination")
}
