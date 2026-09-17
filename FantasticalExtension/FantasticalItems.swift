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

extension TypeID {
  static let fantasticalDestination = TypeID("com.tuna.type.fantastical-destination")
}
