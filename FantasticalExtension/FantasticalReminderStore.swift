import EventKit
import Foundation

/// One long-lived store, confined to this actor: EventKit promises nothing about threads, and an
/// object it hands out must never meet another store, so nothing it returns leaves here.
actor FantasticalReminderStore {
  static let shared = FantasticalReminderStore()

  /// What the helper reports as the source of a Reminders list.
  static let helperSourceName = "Calendar"

  enum Access: Sendable {
    case granted, denied
  }

  enum CompletionError: LocalizedError {
    case notFound
    case readOnly(String)

    var errorDescription: String? {
      switch self {
      case .notFound: return "Reminders no longer lists that task"
      case .readOnly(let list): return "\(list) is read-only"
      }
    }
  }

  private let store = EKEventStore()
  private var observer: NSObjectProtocol?

  func access() async -> Access {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess:
      return .granted
    case .notDetermined:
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .denied }
      let granted = (try? await store.requestFullAccessToReminders()) ?? false
      return granted ? .granted : .denied
    case .restricted, .denied, .writeOnly:
      return .denied
    @unknown default:
      return .denied
    }
  }

  func listIdentifiers() -> Set<String> {
    Set(store.calendars(for: .reminder).map(\.calendarIdentifier))
  }

  func openTasks(in listID: String) async -> [FantasticalAgendaItem] {
    guard let list = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listID }) else {
      return []
    }
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
    let reminders: [EKReminder] = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    startObserving()
    return reminders.map { reminder in
      Self.item(
        listID: listID, key: reminder.calendarItemIdentifier, title: reminder.title ?? "",
        due: reminder.dueDateComponents.flatMap { $0.date ?? Calendar.autoupdatingCurrent.date(from: $0) },
        priority: reminder.priority)
    }
  }

  func complete(id: String) throws {
    guard let parts = FantasticalTaskID.split(id),
      let reminder = store.calendarItem(withIdentifier: parts.key) as? EKReminder
    else { throw CompletionError.notFound }
    guard reminder.calendar?.allowsContentModifications ?? false else {
      throw CompletionError.readOnly(reminder.calendar?.title ?? "That list")
    }
    reminder.isCompleted = true
    try store.save(reminder, commit: true)
  }

  nonisolated static func item(
    listID: String, key: String, title: String, due: Date?, priority: Int
  ) -> FantasticalAgendaItem {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return FantasticalAgendaItem(
      id: FantasticalTaskID.make(listID: listID, key: key), title: trimmed.isEmpty ? "Untitled task" : trimmed,
      calendarID: listID, start: due, end: nil, location: nil, priority: priority)
  }

  /// Fires for every change in the Reminders database, this extension's own saves included, so
  /// an open Tasks group asks for a rebuild instead of holding rows another app has changed.
  private func startObserving() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: store, queue: nil
    ) { _ in
      FantasticalAgendaSupport.postDataDidChange()
    }
  }
}
