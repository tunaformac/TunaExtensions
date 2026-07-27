import AppKit
@preconcurrency import EventKit
import Foundation
import TunaKit

public final class RemindersCatalog: RemindersCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .all)
  }
}

public final class RemindersSearchCatalog: RemindersCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .search)
  }
}

@MainActor
public class RemindersCatalogBase: NSObject, Catalog {
  enum Mode {
    case all
    case search
  }

  public let identifier: String
  public let name: String
  private let mode: Mode

  private let authorization: RemindersAuthorizationProviding
  private let notificationCenter: NotificationCenter
  private var changeObserver: NSObjectProtocol?
  private var store: EKEventStore?

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let refreshTaskStore = LockedValue<Task<Void, Never>?>(nil)
  private let newReminderItem = RemindersNewReminderItem()

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }
    switch mode {
    case .all:
      return itemsStore.readValue { $0 }
    case .search:
      return [newReminderItem]
    }
  }

  fileprivate init(
    definition: CatalogDefinition,
    mode: Mode,
    authorization: RemindersAuthorizationProviding = RemindersAuthorization(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.mode = mode
    self.authorization = authorization
    self.notificationCenter = notificationCenter
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Reminders catalog type instead.")
  }

  deinit {
    if let changeObserver {
      notificationCenter.removeObserver(changeObserver)
    }
    refreshTaskStore.withValue { task in
      task?.cancel()
      task = nil
    }
  }

  public func scan() async {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      messageStore.value = nil
      itemsStore.value = []
      reportScanFinished()
      return
    }

    let store = requireStore()

    guard await authorization.ensureAuthorization(using: store) else {
      messageStore.value = [
        CatalogMessageItem(
          title: "Reminders Access Needed",
          message: "Enable reminders permissions for Tuna to surface your reminders.",
          symbolName: "checklist.unchecked",
          tintColor: .systemOrange
        )
      ]
      itemsStore.value = []
      reportScanFinished()
      return
    }

    messageStore.value = nil

    ensureStoreObserver(for: store)

    let storeBox = UncheckedSendableBox(store)

    let records = await Task.detached(priority: .utility) { [storeBox] in
      await RemindersCatalogBase.fetchRecords(store: storeBox.value)
    }.value

    let items = records.map { record in
      ReminderItem(
        title: record.title,
        identifier: record.identifier,
        listName: record.listName,
        dueDate: record.dueDate,
        isCompleted: record.isCompleted
      )
    }

    switch mode {
    case .all:
      itemsStore.value = items
    case .search:
      break
    }

    reportScanFinished()
  }

  @MainActor
  private func ensureStoreObserver(for store: EKEventStore) {
    guard changeObserver == nil else { return }
    changeObserver = notificationCenter.addObserver(
      forName: .EKEventStoreChanged,
      object: store,
      queue: .main
    ) { [weak self] _ in
      Task { [weak self] in
        await self?.scheduleExternalRefresh()
      }
    }
  }

  @MainActor
  private func scheduleExternalRefresh() {
    refreshTaskStore.withValue { task in
      task?.cancel()
      task = Task.detached(priority: .utility) { [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard let self else { return }
        await self.handleExternalChange()
      }
    }
  }

  private func handleExternalChange() async {
    await scan()
    await MainActor.run {
      reportScanFinished()
    }
  }

  private func requireStore() -> EKEventStore {
    if let store {
      return store
    }
    let store = EKEventStore()
    self.store = store
    return store
  }

  nonisolated private static func fetchRecords(store: EKEventStore) async -> [ReminderRecord] {
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: nil
    )

    let reminders = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { fetched in
        continuation.resume(returning: fetched ?? [])
      }
    }

    var records: [ReminderRecord] = reminders.compactMap { reminder in
      let identifier = reminder.calendarItemIdentifier
      guard !identifier.isEmpty else { return nil }
      let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedTitle = title.isEmpty ? "Untitled Reminder" : title
      let listName = reminder.calendar.title
      let dueDate = reminder.dueDateComponents.flatMap {
        Calendar.autoupdatingCurrent.date(from: $0)
      }
      return ReminderRecord(
        identifier: identifier,
        title: resolvedTitle,
        listName: listName,
        dueDate: dueDate,
        isCompleted: reminder.isCompleted
      )
    }

    records.sort { lhs, rhs in
      switch (lhs.dueDate, rhs.dueDate) {
      case (let l?, let r?) where l != r:
        return l < r
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }

    return records
  }
}

private struct ReminderRecord: Sendable {
  let identifier: String
  let title: String
  let listName: String
  let dueDate: Date?
  let isCompleted: Bool
}
