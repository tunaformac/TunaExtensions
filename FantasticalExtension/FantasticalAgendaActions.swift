import AppKit
import Foundation
import TunaKit

extension FantasticalActionsCatalog {
  static let agendaActionIDs = [
    "reschedule", "rename", "change-location", "delete-item", "add-to-fantastical-calendar",
  ]

  static func agendaActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    items.append(
      makeModifyAction(
        id: "reschedule", title: "Reschedule...", symbolName: "clock.arrow.circlepath",
        field: "when", failure: "Type the new time, for example tomorrow 15h"))
    items.append(
      makeModifyAction(
        id: "rename", title: "Rename...", symbolName: "pencil", field: "title",
        failure: "Type the new title"))
    items.append(
      makeModifyAction(
        id: "change-location", title: "Change Location...", symbolName: "mappin.and.ellipse",
        field: "location", failure: "Type the new location"))

    let delete = PredicateAwareAction(id: "delete-item", title: "Delete from Fantastical") {
      subject, _ in
      guard let entity = subject as? FantasticalAgendaEntity else {
        return .failure("No Fantastical item selected")
      }
      let itemID = entity.item.id
      return .review(
        ActionReviewSession(
          presentation: ActionReviewPresentation(
            title: "Delete from Fantastical?",
            message: "This removes the item from its calendar. Fantastical cannot undo it.",
            sections: [
              ActionReviewSection(
                id: "item", title: "Item",
                rows: [ActionReviewRow(id: itemID, title: entity.title, detail: entity.detail)])
            ],
            confirmButtonTitle: "Delete",
            isDestructive: true),
          handler: { response in
            guard case .confirm = response else { return .cancelled }
            return await FantasticalAgendaActions.delete(id: itemID)
          }))
    }
    delete.systemSymbolName = "trash"
    delete.executionPolicy = .keepVisible
    delete.supportedSubjectTypes = [.fantasticalItem]
    delete.subjectPredicate = { $0 is FantasticalAgendaEntity }
    items.append(delete)

    let addToCalendar = PredicateAwareAction(
      id: "add-to-fantastical-calendar", title: "Add to Fantastical Calendar"
    ) { subject, target in
      guard let calendar = target as? FantasticalCalendarEntity else {
        return .failure("Choose a Fantastical calendar")
      }
      return FantasticalActions.add(subject: subject, calendar: calendar.calendar)
    }
    addToCalendar.targetRequirement = .required
    addToCalendar.systemSymbolName = "calendar.badge.plus"
    addToCalendar.supportedSubjectTypes = [.textSnippet]
    addToCalendar.allowedTargetTypes = [.fantasticalCalendar]
    addToCalendar.targetSearchScope = .catalogs(
      [FantasticalIdentifiers.calendarsCatalog], preparation: .refresh)
    addToCalendar.subjectPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    addToCalendar.targetPredicate = { $0 is FantasticalCalendarEntity }
    items.append(addToCalendar)

    return items
  }

  private static func makeModifyAction(
    id: String, title: String, symbolName: String, field: String, failure: String
  ) -> PredicateAwareAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, target in
      guard let entity = subject as? FantasticalAgendaEntity else {
        return .failure("No Fantastical item selected")
      }
      guard let value = FantasticalURLBuilder.textValue(for: target) else {
        return .failure(failure)
      }
      return await FantasticalAgendaActions.modify(id: entity.item.id, field: field, value: value)
    }
    action.targetRequirement = .required
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.fantasticalItem]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = { $0 is FantasticalAgendaEntity }
    action.targetPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    return action
  }
}

enum FantasticalAgendaActions {
  static func modify(id: String, field: String, value: String) async -> ActionResult {
    await perform("modifyCalendarItem", arguments: ["id": id, field: value])
  }

  static func delete(id: String) async -> ActionResult {
    await perform("deleteCalendarItem", arguments: ["id": id])
  }

  private static func perform(_ tool: String, arguments: [String: Any]) async -> ActionResult {
    do {
      _ = try await FantasticalMCPClient.shared.call(tool, arguments: arguments)
    } catch {
      return .failure(error.localizedDescription)
    }
    FantasticalAgendaSupport.postDataDidChange()
    return .success
  }
}
