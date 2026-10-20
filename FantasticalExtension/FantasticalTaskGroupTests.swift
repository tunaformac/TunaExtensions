import TunaKit
import SQLite3
import XCTest

@testable import TunaFantastical

@MainActor
final class FantasticalTaskGroupTests: XCTestCase {
  private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }

  func testTasksAreGroupedPerListWithOverdueFirst() throws {
    let calendar = paris
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    func list(_ id: String, _ title: String) -> FantasticalCalendar {
      FantasticalCalendar(
        id: id, title: title, isWritable: true, supportsEvents: false, supportsTasks: true,
        sourceName: "Calendar")
    }
    func task(_ key: String, list: String, day: Int?, priority: Int = 0) -> FantasticalAgendaItem {
      FantasticalAgendaItem(
        id: "\(list);\(key)", title: key, calendarID: list,
        start: day.flatMap { calendar.date(from: DateComponents(year: 2026, month: 9, day: $0)) }, end: nil,
        location: nil, timeZone: calendar.timeZone, priority: priority)
    }
    let lists = [
      FantasticalTaskList(
        calendar: list("r", "Reminders"), source: .eventKit,
        items: [
          task("late", list: "r", day: 20), task("undated", list: "r", day: nil),
          task("soon", list: "r", day: 25),
        ]),
      FantasticalTaskList(calendar: list("i", "Inbox"), source: .eventKit, items: []),
      FantasticalTaskList(calendar: list("g", "Google"), source: .store, items: [task("g1", list: "g", day: 21)]),
    ]
    let tasks = FantasticalAgendaSupport.taskSections(lists: lists, now: now, calendar: calendar)
    XCTAssertEqual(tasks.detail, "4 open, 2 overdue")
    XCTAssertEqual(tasks.children.map(\.title), ["Overdue", "Reminders", "Inbox", "Google"])
    XCTAssertEqual(tasks.children.map(\.detail), ["2 items", "3 open", "No open tasks", "1 open"])
    let overdue = try XCTUnwrap(tasks.children.first as? FantasticalSectionItem)
    XCTAssertEqual(overdue.hierarchyChildren().map(\.id), ["fantastical.item.r;late", "fantastical.item.g;g1"])
    let reminders = try XCTUnwrap(tasks.children[1] as? FantasticalSectionItem)
    XCTAssertEqual(
      reminders.hierarchyChildren().map(\.id),
      ["fantastical.item.r;late", "fantastical.item.r;soon", "fantastical.item.r;undated"],
      "due soonest first, undated last")
    XCTAssertEqual(tasks.children.map { ($0 as? FantasticalSectionItem)?.sortOrder }, [0, 1, 2, 3])

    let empty = FantasticalAgendaSupport.taskSections(lists: [], now: now, calendar: calendar)
    XCTAssertEqual(empty.detail, "0 items, no task lists")
    XCTAssertTrue(empty.children.isEmpty)

    let denied = FantasticalAgendaSupport.taskSections(
      lists: [lists[2]], reminderAccessDenied: true, now: now, calendar: calendar)
    let ordered = denied.children.sorted(by: FantasticalAgendaSort.compare)
    XCTAssertEqual(ordered.first?.title, "Reminders access needed")
    XCTAssertEqual(ordered.map(\.title), ["Reminders access needed", "Overdue", "Google"])
    let notice = try XCTUnwrap(ordered.first as? TimestampedCatalogItem)
    let firstSection = try XCTUnwrap(ordered[1] as? TimestampedCatalogItem)
    XCTAssertGreaterThanOrEqual(
      notice.capturedAtDate, firstSection.capturedAtDate, "the time sort keeps the notice on top too")
    XCTAssertEqual(denied.detail, "1 open, 1 overdue")

    let helper = FantasticalTaskList(
      calendar: list("h", "Todoist"), source: .helper,
      items: [task("h1", list: "h", day: 25), task("h2", list: "h", day: 26)])
    XCTAssertEqual(FantasticalAgendaSupport.listDetail(helper), "2 dated, completion unknown")
    XCTAssertEqual(
      FantasticalAgendaSupport.listDetail(
        FantasticalTaskList(calendar: list("h", "Todoist"), source: .helper, items: [])),
      "No open tasks")
  }

  func testTaskSortPutsDueSoonestThenPriorityThenTitle() throws {
    let calendar = paris
    let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
    func task(_ title: String, due: Date?, priority: Int) -> FantasticalAgendaItem {
      FantasticalAgendaItem(
        id: "l;\(title)", title: title, calendarID: "l", start: due, end: nil, location: nil,
        priority: priority)
    }
    let sorted = FantasticalAgendaSupport.sortedTasks([
      task("b none", due: nil, priority: 0), task("a none", due: nil, priority: 0),
      task("low later", due: day.addingTimeInterval(86_400), priority: 9),
      task("medium", due: day, priority: 5), task("high", due: day, priority: 1),
      task("urgent undated", due: nil, priority: 1),
    ])
    XCTAssertEqual(sorted.map(\.title), ["high", "medium", "low later", "urgent undated", "a none", "b none"])
  }

  func testTasksDetailCountsOpenAndOverdue() {
    XCTAssertEqual(FantasticalAgendaSupport.tasksDetail(open: 0, overdue: 0, hasLists: false), "0 items, no task lists")
    XCTAssertEqual(FantasticalAgendaSupport.tasksDetail(open: 0, overdue: 0, hasLists: true), "No open tasks")
    XCTAssertEqual(FantasticalAgendaSupport.tasksDetail(open: 1, overdue: 0, hasLists: true), "1 open")
    XCTAssertEqual(FantasticalAgendaSupport.tasksDetail(open: 12, overdue: 3, hasLists: true), "12 open, 3 overdue")
  }

  func testTaskDetailSaysDueListAndPriority() throws {
    let calendar = paris
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    let allDay = FantasticalAgendaItem(
      id: "r;a", title: "a", calendarID: "r",
      start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)), end: nil, location: nil,
      timeZone: calendar.timeZone, priority: 1)
    let allDayDetail = FantasticalAgendaFormat.detail(
      allDay, calendarTitle: "Reminders", now: now, calendar: calendar, isTask: true)
    XCTAssertTrue(allDayDetail.hasPrefix("Due "), allDayDetail)
    XCTAssertTrue(allDayDetail.contains("25"), allDayDetail)
    XCTAssertFalse(allDayDetail.contains("all day"), allDayDetail)
    XCTAssertTrue(allDayDetail.hasSuffix(" · Reminders · High priority"), allDayDetail)
    let timed = FantasticalAgendaItem(
      id: "r;t", title: "t", calendarID: "r",
      start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 15)), end: nil, location: nil,
      timeZone: calendar.timeZone)
    let timedDetail = FantasticalAgendaFormat.detail(
      timed, calendarTitle: "Reminders", now: now, calendar: calendar, isTask: true)
    XCTAssertTrue(timedDetail.hasPrefix("Due Today, "), timedDetail)
    XCTAssertTrue(timedDetail.hasSuffix(" · Reminders"), timedDetail)
    let undated = FantasticalAgendaItem(id: "r;u", title: "u", calendarID: "r", start: nil, end: nil, location: nil)
    XCTAssertEqual(
      FantasticalAgendaFormat.detail(undated, calendarTitle: "Inbox", now: now, calendar: calendar, isTask: true),
      "No date · Inbox")
    let eventDetail = FantasticalAgendaFormat.detail(allDay, calendarTitle: "Perso", now: now, calendar: calendar)
    XCTAssertTrue(eventDetail.hasSuffix(", all day · Perso"), "an event keeps its wording: \(eventDetail)")
    XCTAssertFalse(eventDetail.hasPrefix("Due "), eventDetail)
  }

  func testEntitiesKnowWhichTasksCanBeCompleted() throws {
    let calendar = paris
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    func list(_ id: String, writable: Bool = true) -> FantasticalCalendar {
      FantasticalCalendar(
        id: id, title: id, isWritable: writable, supportsEvents: false, supportsTasks: true,
        sourceName: "Calendar")
    }
    let item = FantasticalAgendaItem(id: "r;k", title: "k", calendarID: "r", start: nil, end: nil, location: nil)
    let calendars = [list("r"), list("ro", writable: false)]
    XCTAssertTrue(
      FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .eventKit).canComplete)
    XCTAssertFalse(
      FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .store).canComplete)
    XCTAssertFalse(
      FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .helper).canComplete)
    XCTAssertFalse(FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now).canComplete)
    let readOnly = FantasticalAgendaItem(id: "ro;k", title: "k", calendarID: "ro", start: nil, end: nil, location: nil)
    XCTAssertFalse(
      FantasticalAgendaSupport.entity(for: readOnly, calendars: calendars, now: now, source: .eventKit)
        .canComplete)

    let lists = [
      FantasticalTaskList(calendar: list("r"), source: .eventKit, items: [
        FantasticalAgendaItem(id: "r;late", title: "late", calendarID: "r",
          start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)), end: nil, location: nil),
      ]),
      FantasticalTaskList(calendar: list("g"), source: .store, items: [
        FantasticalAgendaItem(id: "g;late", title: "late", calendarID: "g",
          start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 21)), end: nil, location: nil),
      ]),
    ]
    let overdue = try XCTUnwrap(
      FantasticalAgendaSupport.taskSections(lists: lists, now: now, calendar: calendar)
        .children.first as? FantasticalSectionItem)
    XCTAssertEqual(
      overdue.hierarchyChildren().map { ($0 as? FantasticalAgendaEntity)?.canComplete }, [true, false],
      "an overdue row keeps the source of the list it came from")
  }

  func testTaskSortScoreBreaksTiesByPriority() {
    let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func entity(_ id: String, due: Date?, priority: Int) -> FantasticalAgendaEntity {
      FantasticalAgendaEntity(
        item: FantasticalAgendaItem(
          id: id, title: id, calendarID: "l", start: due, end: nil, location: nil, priority: priority),
        calendarTitle: nil, isTask: true)
    }
    XCTAssertGreaterThan(
      entity("high", due: due, priority: 1).sortScore, entity("none", due: due, priority: 0).sortScore)
    XCTAssertGreaterThan(
      entity("sooner", due: due, priority: 0).sortScore,
      entity("later", due: due.addingTimeInterval(1), priority: 1).sortScore)
    XCTAssertGreaterThan(
      entity("undated high", due: nil, priority: 1).sortScore,
      entity("undated none", due: nil, priority: 0).sortScore)
    XCTAssertGreaterThan(
      entity("high", due: due, priority: 1).capturedAtDate, entity("none", due: due, priority: 0).capturedAtDate)
    XCTAssertGreaterThan(
      entity("sooner", due: due, priority: 0).capturedAtDate,
      entity("later", due: due.addingTimeInterval(1), priority: 1).capturedAtDate)
    XCTAssertGreaterThan(
      entity("undated high", due: nil, priority: 1).capturedAtDate,
      entity("undated none", due: nil, priority: 0).capturedAtDate)
  }

  func testCompleteTaskIsOfferedOnEventKitTasksOnly() throws {
    let catalog = FantasticalActionsCatalog(
      definition: ActionCatalogDefinition(identifier: FantasticalIdentifiers.actionCatalog, name: "Fantastical"))
    let complete = try XCTUnwrap(
      catalog.actions.first { $0.id == FantasticalIdentifiers.completeAction } as? PredicateAwareAction)
    XCTAssertEqual(complete.title, "Complete Task")
    XCTAssertEqual(complete.supportedSubjectTypes, [.fantasticalItem])
    XCTAssertEqual(complete.executionPolicy, .keepVisible)
    let item = FantasticalAgendaItem(id: "r;k", title: "k", calendarID: "r", start: nil, end: nil, location: nil)
    XCTAssertTrue(
      complete.subjectPredicate?(
        FantasticalAgendaEntity(item: item, calendarTitle: nil, isTask: true, canComplete: true)) ?? false)
    XCTAssertFalse(
      complete.subjectPredicate?(FantasticalAgendaEntity(item: item, calendarTitle: nil, isTask: true)) ?? true)
    XCTAssertTrue(FantasticalActionsCatalog.agendaActionIDs.contains(FantasticalIdentifiers.completeAction))
  }

  func testTaskSourceRoutesReminderListsAwayFromTheStore() {
    func list(_ id: String, source: String) -> FantasticalCalendar {
      FantasticalCalendar(
        id: id, title: id, isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: source)
    }
    let reminders = list("A3F59DCE", source: FantasticalReminderStore.helperSourceName)
    let google = list("d9836b3d", source: "Google")
    XCTAssertEqual(
      FantasticalAgendaSupport.taskSource(for: reminders, reminderLists: ["A3F59DCE"], storeAvailable: true),
      .eventKit)
    XCTAssertEqual(
      FantasticalAgendaSupport.taskSource(for: reminders, reminderLists: [], storeAvailable: true), .helper,
      "a denied Reminders list is never in the store")
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: google, reminderLists: [], storeAvailable: true), .store)
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: google, reminderLists: [], storeAvailable: false), .helper)
    XCTAssertEqual(
      FantasticalAgendaSupport.taskSource(for: google, reminderLists: ["d9836b3d"], storeAvailable: false),
      .eventKit, "an EventKit id wins whatever the source name says")
  }
}
