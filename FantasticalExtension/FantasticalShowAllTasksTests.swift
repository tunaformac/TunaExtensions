import TunaKit
import XCTest

@testable import TunaFantastical

@MainActor
final class FantasticalShowAllTasksTests: XCTestCase {
  private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }

  private func list(_ id: String, _ title: String) -> FantasticalCalendar {
    FantasticalCalendar(
      id: id, title: title, isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "Calendar")
  }

  private func task(_ key: String, list: String, day: Int?, priority: Int = 0) -> FantasticalAgendaItem {
    let calendar = paris
    return FantasticalAgendaItem(
      id: "\(list);\(key)", title: key, calendarID: list,
      start: day.flatMap { calendar.date(from: DateComponents(year: 2026, month: 9, day: $0)) }, end: nil,
      location: nil, timeZone: calendar.timeZone, priority: priority)
  }

  private func fixture() throws -> (lists: [FantasticalTaskList], now: Date) {
    let now = try XCTUnwrap(paris.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    let lists = [
      FantasticalTaskList(
        calendar: list("r", "Reminders"), source: .eventKit,
        items: [task("late", list: "r", day: 20), task("undated", list: "r", day: nil), task("soon", list: "r", day: 25)]),
      FantasticalTaskList(calendar: list("i", "Inbox"), source: .eventKit, items: []),
      FantasticalTaskList(calendar: list("g", "Google"), source: .store, items: [task("g1", list: "g", day: 21)]),
    ]
    return (lists, now)
  }

  func testFlatListHoldsEveryOpenTaskOnceDueSoonestFirst() throws {
    let (lists, now) = try fixture()
    let tasks = FantasticalAgendaSupport.taskSections(lists: lists, now: now, calendar: paris)
    let expected = [
      "fantastical.item.r;late", "fantastical.item.g;g1", "fantastical.item.r;soon", "fantastical.item.r;undated",
    ]
    XCTAssertEqual(tasks.tasks.map(\.id), expected)
    XCTAssertEqual(
      tasks.tasks.sorted(by: FantasticalAgendaSort.compare).map(\.id), expected,
      "the agenda comparator keeps that order")
    XCTAssertEqual(tasks.tasks.map { ($0 as? FantasticalAgendaEntity)?.canComplete }, [true, false, true, true])
    XCTAssertEqual(tasks.children.map(\.title), ["Overdue", "Reminders", "Inbox", "Google"], "the groups are unchanged")

    let denied = FantasticalAgendaSupport.taskSections(
      lists: lists, reminderAccessDenied: true, now: now, calendar: paris)
    XCTAssertEqual(denied.tasks.first?.title, "Reminders access needed")
    XCTAssertEqual(denied.tasks.count, 5)
    XCTAssertTrue(FantasticalAgendaSupport.taskSections(lists: [], now: now, calendar: paris).tasks.isEmpty)
  }

  func testTasksNodeCarriesItsOwnTypeAndKeepsTheGroupsForTheArrow() throws {
    let (lists, now) = try fixture()
    let sections = FantasticalAgendaSupport.sections(
      from: [:], calendars: lists.map(\.calendar), taskLists: lists, now: now, calendar: paris)
    let node = try XCTUnwrap(sections.first { $0.id == "fantastical.agenda.tasks" } as? FantasticalTaskGroupItem)
    XCTAssertEqual(node.typeID, .fantasticalTaskGroup)
    XCTAssertEqual(node.title, "Tasks")
    XCTAssertEqual(node.detail, "4 open, 2 overdue")
    XCTAssertEqual(node.hierarchyChildren().map(\.title), ["Overdue", "Reminders", "Inbox", "Google"])
    XCTAssertEqual(node.tasks.count, 4)
    for other in sections where other.id != "fantastical.agenda.tasks" {
      XCTAssertEqual(other.typeID, .searchCatalogEntry, other.id)
    }
  }

  func testDeclarationRegistersTheTaskGroupType() {
    let declaration = FantasticalExtension.makeDeclaration()
    let registration = declaration.typeRegistrations.first { $0.typeID == .fantasticalTaskGroup }
    XCTAssertEqual(registration?.inheritsFrom, [.entity])
    XCTAssertEqual(registration?.displayName, "Fantastical Task Groups")
  }
}
