import TunaKit
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
}
