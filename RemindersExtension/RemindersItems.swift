import AppKit
import Foundation
import TunaKit

final class ReminderItem: CatalogItem, TextValueProviding, @unchecked Sendable {
  let reminderIdentifier: String
  let listName: String
  let dueDate: Date?
  let isCompleted: Bool

  var textValue: String { title }

  override var searchText: String {
    [title, listName].joined(separator: " ")
  }

  override var detail: String? {
    var parts: [String] = []
    if !listName.isEmpty {
      parts.append(listName)
    }
    if let dueDate {
      let relative = dueDate.formatted(.relative(presentation: .named))
      parts.append("due \(relative)")
    }
    if parts.isEmpty { return nil }
    return parts.joined(separator: " • ")
  }

  init(title: String, identifier: String, listName: String, dueDate: Date?, isCompleted: Bool) {
    self.reminderIdentifier = identifier
    self.listName = listName
    self.dueDate = dueDate
    self.isCompleted = isCompleted
    super.init(id: identifier, title: title, type: .entity)
    typeID = .reminder
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    let symbol = isCompleted ? "checkmark.circle.fill" : "circle"
    let tint = isCompleted ? NSColor.systemGreen : NSColor.secondaryLabelColor
    return CatalogItemPreview.systemSymbol(symbol, tintColor: tint)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class RemindersNewReminderItem: CatalogEntity, @unchecked Sendable {
  init() {
    super.init(id: "reminders.new", title: "New Reminder", path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    "Create a reminder from typed text"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("plus.circle")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("plus.circle")
  }
}

extension RemindersNewReminderItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    guard let catalogIdentifier else { return false }
    guard catalogIdentifier == "reminders.search" else { return false }
    return action.id == "to"
  }
}

extension TypeID {
  static let reminder = TypeID("com.tuna.type.reminder")
}
