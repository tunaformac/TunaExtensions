import AppKit
@preconcurrency import EventKit
import Foundation
import TunaKit

public final class RemindersActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }


  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let openInReminders = PredicateAwareAction(
      id: "open-in-reminders", title: "Open in Reminders"
    ) { subject, _ in
      guard let reminder = subject as? ReminderItem else {
        return .failure("No reminder selected")
      }
      guard let url = RemindersActions.urlToOpen(reminderIdentifier: reminder.reminderIdentifier)
      else {
        return .failure("Invalid reminder URL")
      }
      NSWorkspace.shared.open(url)
      return .success
    }
    openInReminders.systemSymbolName = "arrow.up.right.square"
    openInReminders.supportedSubjectTypes = [.reminder]
    openInReminders.subjectPredicate = { $0 is ReminderItem }
    items.append(openInReminders)

    let markComplete = PredicateAwareAction(
      id: "mark-complete", title: "Mark Complete"
    ) { subject, _ in
      guard let reminder = subject as? ReminderItem else {
        return .failure("No reminder selected")
      }
      let identifier = reminder.reminderIdentifier
      Task.detached(priority: .utility) {
        _ = await RemindersActions.setCompletion(reminderIdentifier: identifier, completed: true)
      }
      return .success
    }
    markComplete.systemSymbolName = "checkmark.circle"
    markComplete.supportedSubjectTypes = [.reminder]
    markComplete.subjectPredicate = { subject in
      guard let reminder = subject as? ReminderItem else { return false }
      return reminder.isCompleted == false
    }
    items.append(markComplete)

    let createFromText = PredicateAwareAction(
      id: "create-reminder", title: "Create Reminder"
    ) { subject, _ in
      guard subject.typeID == .textSnippet else {
        return .failure("Select text first")
      }
      guard let title = subject.textInputValue() else {
        return .failure("Missing reminder title")
      }
      Task.detached(priority: .utility) {
        await RemindersActions.runCreateReminder(title: title)
      }
      return .success
    }
    createFromText.systemSymbolName = "plus.circle"
    createFromText.supportedSubjectTypes = [.textSnippet]
    createFromText.subjectPredicate = { subject in
      guard let subject else { return false }
      return subject.typeID == .textSnippet && subject.textInputValue() != nil
    }
    items.append(createFromText)

    items.append(CreateReminderInListAction())

    let createFromApp = PredicateAwareAction(
      id: "create-reminder.from-app", title: "Create Reminder"
    ) { _, target in
      guard let title = target?.textInputValue() else {
        return .failure("Missing reminder title")
      }
      Task.detached(priority: .utility) {
        await RemindersActions.runCreateReminder(title: title)
      }
      return .success
    }
    createFromApp.targetRequirement = .required
    createFromApp.systemSymbolName = "plus.circle"
    createFromApp.supportedSubjectTypes = [.application]
    createFromApp.allowedTargetTypes = [.textSnippet]
    createFromApp.subjectPredicate = RemindersActions.isRemindersApplication
    createFromApp.targetPredicate = { item in item?.textInputValue() != nil }
    items.append(createFromApp)

    let toAction = PredicateAwareAction(id: "to", title: "To...") {
      subject, target in
      guard RemindersActions.isNewReminderEntry(subject) else {
        return .failure("Select New Reminder first")
      }
      guard let title = target?.textInputValue() else {
        return .failure("Missing reminder title")
      }
      Task.detached(priority: .utility) {
        await RemindersActions.runCreateReminder(title: title)
      }
      return .success
    }
    toAction.targetRequirement = .required
    toAction.systemSymbolName = "plus.circle"
    toAction.supportedSubjectTypes = Set([TypeID.searchCatalogEntry])
    toAction.allowedTargetTypes = Set([TypeID.textSnippet])
    toAction.subjectPredicate = { subject in RemindersActions.isNewReminderEntry(subject) }
    toAction.targetPredicate = { item in item?.textInputValue() != nil }
    items.append(toAction)

    return items
  }
}

private final class CreateReminderInListAction: CatalogAction, ActionPredicateProviding,
  @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate? = { subject in
    subject?.textInputValue() != nil
  }
  var targetPredicate: CatalogActionTargetPredicate?

  init() {
    super.init(
      id: "create-reminder-in-list",
      title: "Add to Reminders List"
    ) { subject, target in
      await Self.perform(subjects: [subject], target: target)
    }
    batchCallback = { subjects, target in
      await Self.perform(subjects: subjects, target: target)
    }
    targetRequirement = .required
    systemSymbolName = "text.badge.plus"
    supportedSubjectTypes = [.textSnippet]
    allowedTargetTypes = [.reminderList]
    targetSearchScope = .catalogs(
      ["reminders.lists"],
      preparation: .refresh
    )
  }

  private static func perform(subjects: [CatalogItem], target: CatalogItem?) async -> ActionResult {
    guard subjects.count == 1, let title = subjects.first?.textInputValue() else {
      return .failure("Missing reminder title")
    }
    guard let list = target as? ReminderListItem else {
      return .failure("Select a reminders list")
    }

    let completion = await RemindersActions.createReminder(
      title: title,
      calendarIdentifier: list.calendarIdentifier
    )
    switch completion.disposition {
    case .success, .successWithoutResult:
      return .success
    case .failure(let message):
      return .failure(message)
    @unknown default:
      return .failure("Unable to create reminder")
    }
  }
}

private enum RemindersActions {
  static func urlToOpen(reminderIdentifier: String) -> URL? {
    let trimmed = reminderIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: "x-apple-reminderkit://REMCDReminder/\(trimmed)")
  }

  static func isNewReminderEntry(_ subject: CatalogItem?) -> Bool {
    guard let subject else { return false }
    guard subject.typeID == .searchCatalogEntry else { return false }
    return subject.id == "reminders.new"
  }

  static func isRemindersApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.apple.reminders"
  }

  static func runCreateReminder(title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      UserFeedback.beep()
      return
    }

    let completion = await createReminder(title: trimmed)
    if case .failure = completion.disposition {
      UserFeedback.beep()
    }
  }

  static func setCompletion(reminderIdentifier: String, completed: Bool) async
    -> CommandTaskCompletion
  {
    let store = EKEventStore()
    let authorization = RemindersAuthorization()
    guard await authorization.ensureAuthorization(using: store) else {
      return .failure(message: "Reminders access denied")
    }

    guard let item = store.calendarItem(withIdentifier: reminderIdentifier) as? EKReminder else {
      return .failure(message: "Reminder not found")
    }

    item.isCompleted = completed

    do {
      try store.save(item, commit: true)
      return .successWithoutResult()
    } catch {
      return .failure(message: error.localizedDescription)
    }
  }

  static func createReminder(title: String, calendarIdentifier: String? = nil) async
    -> CommandTaskCompletion
  {
    let store = EKEventStore()
    let authorization = RemindersAuthorization()
    guard await authorization.ensureAuthorization(using: store) else {
      return .failure(message: "Reminders access denied")
    }

    let calendar: EKCalendar?
    if let calendarIdentifier {
      guard let selectedCalendar = store.calendar(withIdentifier: calendarIdentifier) else {
        return .failure(message: "Reminders list no longer exists")
      }
      guard selectedCalendar.allowsContentModifications else {
        return .failure(message: "Reminders list is read-only")
      }
      calendar = selectedCalendar
    } else {
      calendar = store.defaultCalendarForNewReminders()
        ?? store.calendars(for: .reminder).first
    }
    guard let calendar else {
      return .failure(message: "No reminders list available")
    }

    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Missing reminder title")
    }

    let reminder = EKReminder(eventStore: store)
    reminder.title = trimmed
    reminder.calendar = calendar

    do {
      try store.save(reminder, commit: true)
      return .successWithoutResult()
    } catch {
      return .failure(message: error.localizedDescription)
    }
  }
}
