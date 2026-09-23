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
