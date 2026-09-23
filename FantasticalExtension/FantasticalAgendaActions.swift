import AppKit
import Foundation
import TunaKit

extension FantasticalActionsCatalog {
  static let agendaActionIDs = [
    FantasticalIdentifiers.rescheduleAction, "rename", "change-location", FantasticalIdentifiers.completeAction,
    "delete-item", "add-to-fantastical-calendar",
  ]

  static func agendaActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    items.append(
      makeModifyAction(
        id: FantasticalIdentifiers.rescheduleAction, title: "Reschedule...", symbolName: "clock.arrow.circlepath",
        field: "when", failure: "Type the new time, for example tomorrow 15h"))
    items.append(
      makeModifyAction(
        id: "rename", title: "Rename...", symbolName: "pencil", field: "title",
        failure: "Type the new title"))
    let changeLocation = makeModifyAction(
      id: "change-location", title: "Change Location...", symbolName: "mappin.and.ellipse",
      field: "location", failure: "Type the new location")
    changeLocation.subjectPredicate = { subject in
      guard let entity = subject as? FantasticalAgendaEntity else { return false }
      return entity.isEditable && !entity.isTask
    }
    items.append(changeLocation)

    let complete = PredicateAwareAction(id: FantasticalIdentifiers.completeAction, title: "Complete Task") {
      subject, _ in
      guard let entity = subject as? FantasticalAgendaEntity, entity.canComplete else {
        return .failure("Only a Reminders task can be completed from Tuna")
      }
      return await FantasticalAgendaActions.complete(id: entity.item.id)
    }
    complete.systemSymbolName = "checkmark.circle"
    complete.executionPolicy = .keepVisible
    complete.supportedSubjectTypes = [.fantasticalItem]
    complete.subjectPredicate = { ($0 as? FantasticalAgendaEntity)?.canComplete == true }
    items.append(complete)

    let delete = PredicateAwareAction(id: "delete-item", title: "Delete from Fantastical") {
      subject, _ in
      guard let entity = subject as? FantasticalAgendaEntity else {
        return .failure("No Fantastical item selected")
      }
      guard entity.isEditable else { return .failure(readOnlyFailure(entity)) }
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
    delete.subjectPredicate = { ($0 as? FantasticalAgendaEntity)?.isEditable == true }
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
      guard entity.isEditable else { return .failure(readOnlyFailure(entity)) }
      guard field != "location" || !entity.isTask else {
        return .failure("Fantastical keeps no location on a task")
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
    action.subjectPredicate = { ($0 as? FantasticalAgendaEntity)?.isEditable == true }
    action.targetPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    return action
  }
}

extension FantasticalActionsCatalog {
  static func readOnlyFailure(_ entity: FantasticalAgendaEntity) -> String {
    let name = entity.calendarTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "That calendar"
    return "\(name) is read-only in Fantastical"
  }
}

enum FantasticalAgendaActions {
  static func modify(id: String, field: String, value: String) async -> ActionResult {
    await perform("modifyCalendarItem", arguments: ["id": id, field: value])
  }

  static func delete(id: String) async -> ActionResult {
    await perform("deleteCalendarItem", arguments: ["id": id])
  }

  /// The reminder store's own observer posts the change for this save, so posting it here too
  /// rebuilt the agenda twice.
  static func complete(id: String) async -> ActionResult {
    do {
      try await FantasticalReminderStore.shared.complete(id: id)
    } catch {
      return .failure(error.localizedDescription)
    }
    return .success
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
