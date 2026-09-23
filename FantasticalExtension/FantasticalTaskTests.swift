import TunaKit
import SQLite3
import XCTest

@testable import TunaFantastical

@MainActor
final class FantasticalTaskTests: XCTestCase {
  private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }

  func testTaskIDJoinsListAndKeyTheWayTheHelperDoes() {
    XCTAssertEqual(FantasticalTaskID.make(listID: "F16DD188", key: "9D5E1A73"), "F16DD188;9D5E1A73")
    let parts = FantasticalTaskID.split("d9836b3d;dFFJSjMt;tail")
    XCTAssertEqual(parts?.listID, "d9836b3d")
    XCTAssertEqual(parts?.key, "dFFJSjMt;tail", "only the first separator splits")
    XCTAssertNil(FantasticalTaskID.split("no-separator"))
    XCTAssertNil(FantasticalTaskID.split("list;"), "an empty key is no id")
  }

  func testPriorityFollowsTheRFC5545Buckets() {
    func item(_ priority: Int) -> FantasticalAgendaItem {
      FantasticalAgendaItem(id: "l;\(priority)", title: "t", calendarID: "l", start: nil, end: nil, location: nil, priority: priority)
    }
    XCTAssertNil(item(0).priorityLabel)
    XCTAssertEqual(item(1).priorityLabel, "High priority")
    XCTAssertEqual(item(4).priorityLabel, "High priority")
    XCTAssertEqual(item(5).priorityLabel, "Medium priority")
    XCTAssertEqual(item(9).priorityLabel, "Low priority")
    XCTAssertEqual(item(0).priorityRank, 10, "no priority sorts after every priority")
    XCTAssertEqual(item(1).priorityRank, 1)
  }

  func testOverdueUsesTheDayForAllDayAndTheInstantForTimed() throws {
    let calendar = paris
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    func task(day: Int, hour: Int? = nil) -> FantasticalAgendaItem {
      var parts = DateComponents(year: 2026, month: 9, day: day)
      parts.hour = hour
      return FantasticalAgendaItem(
        id: "l;\(day)-\(hour ?? 0)", title: "t", calendarID: "l",
        start: calendar.date(from: parts), end: nil, location: nil, timeZone: calendar.timeZone)
    }
    XCTAssertTrue(task(day: 22).isOverdue(now: now, calendar: calendar), "yesterday, all day")
    XCTAssertFalse(task(day: 23).isOverdue(now: now, calendar: calendar), "due today, all day, is not late yet")
    XCTAssertTrue(task(day: 23, hour: 9).isOverdue(now: now, calendar: calendar), "an hour ago")
    XCTAssertFalse(task(day: 23, hour: 11).isOverdue(now: now, calendar: calendar))
    let undated = FantasticalAgendaItem(id: "l;u", title: "t", calendarID: "l", start: nil, end: nil, location: nil)
    XCTAssertFalse(undated.isOverdue(now: now, calendar: calendar))
  }

  func testArchivedTaskRoundTripsUnderFantasticalsClassName() throws {
    let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let task = FantasticalArchivedTask(title: "Buy stamps", priority: 5, dueDate: due, completed: false)
    let data = try archive(task)
    let decoded = try XCTUnwrap(FantasticalArchivedTask.decode(from: data))
    XCTAssertEqual(decoded.title, "Buy stamps")
    XCTAssertEqual(decoded.priority, 5)
    XCTAssertEqual(decoded.dueDate, due)
    XCTAssertFalse(decoded.completed)
    XCTAssertNil(FantasticalArchivedTask.decode(from: Data("not an archive".utf8)))
  }

  func testStoreReaderReturnsOpenTasksOfOneListOnly() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "fantastical-\(UUID().uuidString).fcdata")
    defer { try? FileManager.default.removeItem(at: url) }
    let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
    try makeStore(
      at: url,
      rows: [
        (1, "calendarItems-google", "g1", FantasticalArchivedTask(title: "Open one", priority: 1, dueDate: due, completed: false), 0, 0),
        (2, "calendarItems-google", "g2", FantasticalArchivedTask(title: "Done one", priority: 0, dueDate: nil, completed: true), 1, 0),
        (3, "calendarItems-google", "g3", FantasticalArchivedTask(title: "Hidden one", priority: 0, dueDate: nil, completed: false), 0, 1),
        (4, "calendarItems-other", "o1", FantasticalArchivedTask(title: "Elsewhere", priority: 0, dueDate: nil, completed: false), 0, 0),
        (5, "calendarItems-google", "g4", FantasticalArchivedTask(title: "Undated", priority: 9, dueDate: nil, completed: false), 0, nil),
      ])
    let reader = FantasticalStoreReader(url: url)
    XCTAssertTrue(reader.isAvailable)
    let items = try reader.openTasks(in: "google")
    XCTAssertEqual(items.map(\.id), ["google;g1", "google;g4"])
    XCTAssertEqual(items.map(\.title), ["Open one", "Undated"])
    XCTAssertEqual(items.map(\.priority), [1, 9])
    XCTAssertEqual(items.first?.start, due)
    XCTAssertNil(items.last?.start)
    XCTAssertEqual(items.first?.calendarID, "google")
    XCTAssertFalse(FantasticalStoreReader(url: url.appending(path: "missing")).isAvailable)
  }

  func testStoreReaderThrowsWhenTheStoreCannotBeRead() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "fantastical-\(UUID().uuidString).fcdata")
    defer { try? FileManager.default.removeItem(at: url) }
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle)
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "CREATE TABLE database2 (rowid INTEGER PRIMARY KEY, collection CHAR NOT NULL, key CHAR NOT NULL, data BLOB, metadata BLOB);",
        nil, nil, nil),
      SQLITE_OK)
    XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
    XCTAssertThrowsError(try FantasticalStoreReader(url: url).openTasks(in: "google")) { error in
      XCTAssertTrue(error is FantasticalStoreReader.ReadError, "\(error)")
    }
    let directory = FantasticalStoreReader(url: FileManager.default.temporaryDirectory)
    XCTAssertThrowsError(try directory.openTasks(in: "google")) { error in
      XCTAssertTrue(error is FantasticalStoreReader.ReadError, "\(error)")
    }
  }

  func testStoreReaderThrowsWhenItHoldsNoSuchList() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "fantastical-\(UUID().uuidString).fcdata")
    defer { try? FileManager.default.removeItem(at: url) }
    try makeStore(
      at: url,
      rows: [
        (
          1, "calendarItems-other", "o1",
          FantasticalArchivedTask(title: "Elsewhere", priority: 0, dueDate: nil, completed: false), 0, 0
        )
      ])
    XCTAssertThrowsError(try FantasticalStoreReader(url: url).openTasks(in: "google")) { error in
      XCTAssertTrue(error is FantasticalStoreReader.ReadError, "\(error)")
      if case .unknownList(let id) = error as? FantasticalStoreReader.ReadError {
        XCTAssertEqual(id, "google")
      } else {
        XCTFail("expected unknownList, got \(error)")
      }
    }
  }

  func testStoreReaderReturnsNoTasksWhenTheListHoldsOnlyCompletedOnes() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "fantastical-\(UUID().uuidString).fcdata")
    defer { try? FileManager.default.removeItem(at: url) }
    try makeStore(
      at: url,
      rows: [
        (
          1, "calendarItems-google", "g1",
          FantasticalArchivedTask(title: "Done one", priority: 0, dueDate: nil, completed: true), 1, 0
        )
      ])
    XCTAssertEqual(try FantasticalStoreReader(url: url).openTasks(in: "google").count, 0)
  }

  func testReminderRowsBecomeItemsWithTheHelperIdShape() throws {
    let calendar = paris
    let due = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
    let item = FantasticalReminderStore.item(
      listID: "A3F59DCE", key: "9D5E1A73", title: "  Call the bank ", due: due, priority: 1)
    XCTAssertEqual(item.id, "A3F59DCE;9D5E1A73")
    XCTAssertEqual(item.calendarID, "A3F59DCE")
    XCTAssertEqual(item.title, "Call the bank")
    XCTAssertEqual(item.start, due)
    XCTAssertNil(item.end)
    XCTAssertEqual(item.priority, 1)
    XCTAssertEqual(
      FantasticalReminderStore.item(listID: "l", key: "k", title: "   ", due: nil, priority: 0).title,
      "Untitled task")
  }

  func testTasksAreGroupedPerListWithOverdueFirst() throws {
    let calendar = paris
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
    func list(_ id: String, _ title: String) -> FantasticalCalendar {
      FantasticalCalendar(id: id, title: title, isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "Calendar")
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
        items: [task("late", list: "r", day: 20), task("undated", list: "r", day: nil), task("soon", list: "r", day: 25)]),
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
      FantasticalAgendaItem(id: "l;\(title)", title: title, calendarID: "l", start: due, end: nil, location: nil, priority: priority)
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
    let allDayDetail = FantasticalAgendaFormat.detail(allDay, calendarTitle: "Reminders", now: now, calendar: calendar, isTask: true)
    XCTAssertTrue(allDayDetail.hasPrefix("Due "), allDayDetail)
    XCTAssertTrue(allDayDetail.contains("25"), allDayDetail)
    XCTAssertFalse(allDayDetail.contains("all day"), allDayDetail)
    XCTAssertTrue(allDayDetail.hasSuffix(" · Reminders · High priority"), allDayDetail)
    let timed = FantasticalAgendaItem(
      id: "r;t", title: "t", calendarID: "r",
      start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 15)), end: nil, location: nil,
      timeZone: calendar.timeZone)
    let timedDetail = FantasticalAgendaFormat.detail(timed, calendarTitle: "Reminders", now: now, calendar: calendar, isTask: true)
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
      FantasticalCalendar(id: id, title: id, isWritable: writable, supportsEvents: false, supportsTasks: true, sourceName: "Calendar")
    }
    let item = FantasticalAgendaItem(id: "r;k", title: "k", calendarID: "r", start: nil, end: nil, location: nil)
    let calendars = [list("r"), list("ro", writable: false)]
    XCTAssertTrue(FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .eventKit).canComplete)
    XCTAssertFalse(FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .store).canComplete)
    XCTAssertFalse(FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now, source: .helper).canComplete)
    XCTAssertFalse(FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: now).canComplete)
    let readOnly = FantasticalAgendaItem(id: "ro;k", title: "k", calendarID: "ro", start: nil, end: nil, location: nil)
    XCTAssertFalse(FantasticalAgendaSupport.entity(for: readOnly, calendars: calendars, now: now, source: .eventKit).canComplete)

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
      FantasticalAgendaSupport.taskSections(lists: lists, now: now, calendar: calendar).children.first as? FantasticalSectionItem)
    XCTAssertEqual(
      overdue.hierarchyChildren().map { ($0 as? FantasticalAgendaEntity)?.canComplete }, [true, false],
      "an overdue row keeps the source of the list it came from")
  }

  func testTaskSortScoreBreaksTiesByPriority() {
    let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func entity(_ id: String, due: Date?, priority: Int) -> FantasticalAgendaEntity {
      FantasticalAgendaEntity(
        item: FantasticalAgendaItem(id: id, title: id, calendarID: "l", start: due, end: nil, location: nil, priority: priority),
        calendarTitle: nil, isTask: true)
    }
    XCTAssertGreaterThan(entity("high", due: due, priority: 1).sortScore, entity("none", due: due, priority: 0).sortScore)
    XCTAssertGreaterThan(entity("sooner", due: due, priority: 0).sortScore, entity("later", due: due.addingTimeInterval(1), priority: 1).sortScore)
    XCTAssertGreaterThan(entity("undated high", due: nil, priority: 1).sortScore, entity("undated none", due: nil, priority: 0).sortScore)
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
    XCTAssertTrue(complete.subjectPredicate?(FantasticalAgendaEntity(item: item, calendarTitle: nil, isTask: true, canComplete: true)) ?? false)
    XCTAssertFalse(complete.subjectPredicate?(FantasticalAgendaEntity(item: item, calendarTitle: nil, isTask: true)) ?? true)
    XCTAssertTrue(FantasticalActionsCatalog.agendaActionIDs.contains(FantasticalIdentifiers.completeAction))
  }

  func testTaskSourceRoutesReminderListsAwayFromTheStore() {
    func list(_ id: String, source: String) -> FantasticalCalendar {
      FantasticalCalendar(id: id, title: id, isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: source)
    }
    let reminders = list("A3F59DCE", source: FantasticalReminderStore.helperSourceName)
    let google = list("d9836b3d", source: "Google")
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: reminders, reminderLists: ["A3F59DCE"], storeAvailable: true), .eventKit)
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: reminders, reminderLists: [], storeAvailable: true), .helper, "a denied Reminders list is never in the store")
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: google, reminderLists: [], storeAvailable: true), .store)
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: google, reminderLists: [], storeAvailable: false), .helper)
    XCTAssertEqual(FantasticalAgendaSupport.taskSource(for: google, reminderLists: ["d9836b3d"], storeAvailable: false), .eventKit, "an EventKit id wins whatever the source name says")
  }

  private func archive(_ task: FantasticalArchivedTask) throws -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.setClassName(FantasticalArchivedTask.archivedClassName, for: FantasticalArchivedTask.self)
    archiver.encode(task, forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private func makeStore(
    at url: URL, rows: [(Int, String, String, FantasticalArchivedTask, Int, Int?)]
  ) throws {
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE database2 (rowid INTEGER PRIMARY KEY, collection CHAR NOT NULL, key CHAR NOT NULL, data BLOB, metadata BLOB);
      CREATE TABLE secondaryIndex_index_calendarItems (rowid INTEGER PRIMARY KEY, hidden INTEGER, completed INTEGER);
      """
    XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (rowid, collection, key, task, completed, hidden) in rows {
      let data = try archive(task)
      var insert: OpaquePointer?
      XCTAssertEqual(
        sqlite3_prepare_v2(db, "INSERT INTO database2 (rowid, collection, key, data) VALUES (?, ?, ?, ?)", -1, &insert, nil),
        SQLITE_OK)
      sqlite3_bind_int64(insert, 1, Int64(rowid))
      sqlite3_bind_text(insert, 2, collection, -1, transient)
      sqlite3_bind_text(insert, 3, key, -1, transient)
      data.withUnsafeBytes { bytes in
        _ = sqlite3_bind_blob(insert, 4, bytes.baseAddress, Int32(bytes.count), transient)
      }
      XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
      sqlite3_finalize(insert)
      var index: OpaquePointer?
      XCTAssertEqual(
        sqlite3_prepare_v2(db, "INSERT INTO secondaryIndex_index_calendarItems (rowid, hidden, completed) VALUES (?, ?, ?)", -1, &index, nil),
        SQLITE_OK)
      sqlite3_bind_int64(index, 1, Int64(rowid))
      if let hidden { sqlite3_bind_int(index, 2, Int32(hidden)) } else { sqlite3_bind_null(index, 2) }
      sqlite3_bind_int(index, 3, Int32(completed))
      XCTAssertEqual(sqlite3_step(index), SQLITE_DONE)
      sqlite3_finalize(index)
    }
  }
}
