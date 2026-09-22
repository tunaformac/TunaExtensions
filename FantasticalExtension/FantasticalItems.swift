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

final class FantasticalNewItemRoot: FantasticalNewItemEntry, CatalogHierarchyNode, @unchecked Sendable {
  private static let calendarLoad = DeferredCatalogLoadState()
  /// Last load failure, cleared once shown, so a failing helper is not restarted on every
  /// rebuild of this node.
  private static let lastLoadError = LockedValue<Error?>(nil)

  func hierarchyChildren() -> [CatalogItem] {
    let matching = FantasticalAgendaSupport.knownCalendars.readValue { $0 }
      .filter { $0.isWritable && (isTask ? $0.supportsTasks : $0.supportsEvents) }
    guard matching.isEmpty else {
      return matching.map { FantasticalNewItemEntry(task: isTask, calendar: $0) }
    }
    if let error = Self.lastLoadError.value {
      Self.lastLoadError.value = nil
      return [FantasticalAgendaSupport.errorItem(error)]
    }
    Self.loadCalendars()
    return [
      CatalogLoadingItem(
        title: "Loading Calendars", message: "Asking Fantastical for your calendars.")
    ]
  }

  /// Reporting the scan once the helper answers rebuilds this node with the calendars in it,
  /// instead of making the user leave the pane and come back.
  static func loadCalendars() {
    calendarLoad.requestLoadIfNeeded {
      Task {
        do {
          _ = try await FantasticalAgendaSupport.calendars()
          lastLoadError.value = nil
          calendarLoad.markLoadCompleted()
        } catch {
          lastLoadError.value = error
          calendarLoad.reset()
        }
        FantasticalAgendaSupport.postScanFinished(identifier: FantasticalIdentifiers.catalog)
      }
    }
  }

  static func invalidateCalendars() {
    calendarLoad.reset()
  }
}

extension TypeID {
  static let fantasticalDestination = TypeID("com.tuna.type.fantastical-destination")
}
