import AppKit
import TunaKit
import XCTest

@testable import TunaReminders

@MainActor
final class RemindersExtensionTests: XCTestCase {
  func testCreateInListActionUsesAsyncScopedTargetLoading() throws {
    let catalog = RemindersActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "reminders.actions", name: "Reminders")
    )
    let action = try XCTUnwrap(catalog.actions.first { $0.id == "create-reminder-in-list" })

    XCTAssertNotNil(action.batchCallback)
    XCTAssertEqual(action.targetSearchScope, .catalogs(["reminders.lists"], preparation: .refresh))
    XCTAssertEqual(action.allowedTargetTypes, [.reminderList])
    if case .required = action.targetRequirement {
      // Expected.
    } else {
      XCTFail("Add to Reminders List must require a target")
    }
  }

  func testListsCatalogLoadsOnlyWhenUsedAsAnActionTarget() {
    let catalog = RemindersListsCatalog(
      definition: CatalogDefinition(
        identifier: "reminders.lists",
        name: "Reminder Lists",
        enabledByDefault: true,
        settings: []
      )
    )

    XCTAssertFalse(catalog.scansOnStartup)
  }

  func testReminderListStatusRemainsANonSelectableCatalogMessage() {
    let item = reminderListStatusItem(
      title: "Reminders Access Needed",
      message: "Enable reminders access.",
      symbolName: "checklist.unchecked",
      tintColor: .systemOrange
    )

    // Tuna excludes CatalogMessageItem instances from keyboard and pointer selection,
    // independently of the type used to keep them visible in a scoped target search.
    XCTAssertTrue(item is CatalogMessageItem)
    XCTAssertEqual(item.typeID, .reminderList)
  }
}
