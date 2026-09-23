import AppKit
import Foundation
import TunaKit

final class FantasticalAgendaEntity: CatalogEntity, CopyRepresentationProviding, TimestampedCatalogItem,
  FantasticalScoredItem, @unchecked Sendable
{
  var sortScore: Double { FantasticalAgendaSort.itemScore(start: item.start) }
  var capturedAtDate: Date { FantasticalAgendaSort.itemTimestamp(start: item.start) }
  let item: FantasticalAgendaItem
  let calendarTitle: String?
  let isTask: Bool
  /// Whether the item's calendar accepts writes. An item Tuna cannot match to a known calendar
  /// stays editable, so the helper, not a guess here, has the last word.
  let isEditable: Bool
  private let detailText: String

  init(
    item: FantasticalAgendaItem, calendarTitle: String?, isTask: Bool, isEditable: Bool = true,
    now: Date = Date()
  ) {
    self.item = item
    self.calendarTitle = calendarTitle
    self.isTask = isTask
    self.isEditable = isEditable
    self.detailText = FantasticalAgendaFormat.detail(item, calendarTitle: calendarTitle, now: now)
    super.init(id: "fantastical.item.\(item.id)", title: item.title, path: nil)
    typeID = .fantasticalItem
  }

  override var detail: String? { detailText }

  var copyRepresentation: String? { "\(title) · \(detailText)" }

  override var searchKeys: [String] {
    var keys = [title]
    if let calendarTitle, !calendarTitle.isEmpty { keys.append(calendarTitle) }
    if let location = item.location { keys.append(location) }
    return keys
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    if isTask {
      return .systemSymbol("checkmark.circle", tintColor: .systemBlue)
    }
    if let span = item.span(), span.upperBound < Date() {
      return .systemSymbol("calendar", tintColor: .secondaryLabelColor)
    }
    return .systemSymbol("calendar", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class FantasticalCalendarEntity: CatalogEntity, @unchecked Sendable {
  let calendar: FantasticalCalendar

  init(calendar: FantasticalCalendar) {
    self.calendar = calendar
    super.init(id: "fantastical.calendar.\(calendar.id)", title: calendar.title, path: nil)
    typeID = .fantasticalCalendar
  }

  override var detail: String? {
    var parts = [calendar.sourceName]
    parts.append(calendar.supportsTasks ? "Tasks" : "Events")
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(
      symbolName: calendar.supportsTasks ? "checklist" : "calendar",
      color: calendar.supportsTasks ? .blue : .red,
      maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class FantasticalSectionItem: CatalogEntity, CatalogHierarchyNode, TimestampedCatalogItem,
  FantasticalScoredItem, @unchecked Sendable
{
  let sortOrder: Int
  var sortScore: Double { FantasticalAgendaSort.sectionScore(sortOrder) }
  var capturedAtDate: Date { FantasticalAgendaSort.sectionTimestamp(sortOrder) }
  private let children: [CatalogItem]
  private let generation: Int
  private let symbolName: String
  private let iconColor: CatalogIconColor
  private let detailText: String?

  init(
    title: String, id: String, detail: String?, symbolName: String, iconColor: CatalogIconColor,
    children: [CatalogItem], sortOrder: Int = 0
  ) {
    self.sortOrder = sortOrder
    self.children = children
    self.generation = FantasticalAgendaSupport.dataGeneration.value
    self.symbolName = symbolName
    self.iconColor = iconColor
    self.detailText = detail
    super.init(id: id, title: title, path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? { detailText }

  /// An open pane keeps the rows it was built with. When a write has landed since, ask the host
  /// to rebuild this node rather than leaving those rows on screen for the rest of the session.
  func hierarchyChildren() -> [CatalogItem] {
    if generation != FantasticalAgendaSupport.dataGeneration.value {
      FantasticalAgendaSupport.postScanFinished(identifier: FantasticalIdentifiers.agendaCatalog)
    }
    return children
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: symbolName, color: iconColor, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension TypeID {
  static let fantasticalItem = TypeID("com.tuna.type.fantastical-item")
  static let fantasticalCalendar = TypeID("com.tuna.type.fantastical-calendar")
}
