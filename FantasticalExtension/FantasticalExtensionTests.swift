import TunaKit
import XCTest

@testable import TunaFantastical

@MainActor
final class FantasticalExtensionTests: XCTestCase {
  func testParseURLEncodesSentenceAndPreviewsByDefault() throws {
    let url = try XCTUnwrap(
      FantasticalURLBuilder.parseURL(
        sentence: " Lunch with Sam friday 12h30 +1 ", task: false, addImmediately: false,
        miniWindow: false))

    XCTAssertEqual(url.scheme, "x-fantastical3")
    XCTAssertEqual(url.host, "parse")
    XCTAssertEqual(url.query, "sentence=Lunch%20with%20Sam%20friday%2012h30%20%2B1")
  }

  func testParseURLAddsTaskAndAddFlags() throws {
    let url = try XCTUnwrap(
      FantasticalURLBuilder.parseURL(
        sentence: "Call bank", task: true, addImmediately: true, miniWindow: true))

    XCTAssertEqual(url.scheme, "x-fantastical-mini")
    XCTAssertEqual(url.query, "sentence=Call%20bank&task=1&add=1")
  }

  func testParseURLRejectsBlankText() {
    XCTAssertNil(
      FantasticalURLBuilder.parseURL(
        sentence: "   ", task: false, addImmediately: false, miniWindow: false))
  }

  func testShowURLsMatchFantasticalDocumentation() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23)))

    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .today, now: now, calendar: calendar)?.absoluteString,
      "x-fantastical3://date/2026-09-17")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .tomorrow, now: now, calendar: calendar)?.absoluteString,
      "x-fantastical3://date/2026-09-18")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .calendar)?.absoluteString,
      "x-fantastical3://show/calendar")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .miniWindow)?.absoluteString,
      "x-fantastical-mini://show/mini")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .calendarSet("Work Week"))?.absoluteString,
      "x-fantastical3://show/set?name=Work%20Week")
  }

  func testSearchURL() {
    XCTAssertEqual(
      FantasticalURLBuilder.searchURL(query: "dentist", miniWindow: false)?.absoluteString,
      "x-fantastical3://search?s=dentist")
  }

  func testParseDateAcceptsISOAndWholeTextDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!

    let iso = try XCTUnwrap(FantasticalURLBuilder.parseDate(from: "2026-10-03", calendar: calendar))
    let components = calendar.dateComponents([.year, .month, .day], from: iso)
    XCTAssertEqual([components.year, components.month, components.day], [2026, 10, 3])

    XCTAssertNotNil(FantasticalURLBuilder.parseDate(from: "tomorrow", calendar: calendar))
  }

  func testParseDateRejectsSentencesAndBlankText() {
    XCTAssertNil(FantasticalURLBuilder.parseDate(from: "Lunch with Sam friday"))
    XCTAssertNil(FantasticalURLBuilder.parseDate(from: ""))
  }

  func testCalendarSetParsingTrimsDeduplicatesAndDropsBlanks() {
    XCTAssertEqual(
      FantasticalSettings.parseCalendarSets(" Work, Perso,, Work \n Family "),
      ["Work", "Perso", "Family"])
    XCTAssertEqual(FantasticalSettings.parseCalendarSets(""), [])
  }

  func testCatalogListsFixedViewsThenCalendarSets() {
    let items = FantasticalCatalog.makeItems(calendarSets: ["Work"])

    XCTAssertEqual(
      items.map(\.id),
      [
        "fantastical.view.today", "fantastical.view.tomorrow", "fantastical.view.calendar",
        "fantastical.view.mini", "fantastical.set.Work",
      ])
    XCTAssertTrue(items.allSatisfy { $0.typeID == .fantasticalDestination })
    XCTAssertEqual(items.first?.searchText, "Fantastical Today")
  }

  func testActionsCatalogDeclaresEveryActionAndTheDefaultRanking() throws {
    let catalog = FantasticalActionsCatalog(
      definition: ActionCatalogDefinition(
        identifier: FantasticalIdentifiers.actionCatalog, name: "Fantastical"))
    let ids = catalog.actions.map(\.id)

    XCTAssertTrue(ids.contains(FantasticalIdentifiers.showAction))
    for id in FantasticalActionsCatalog.textActionIDs + FantasticalActionsCatalog.appActionIDs {
      XCTAssertTrue(ids.contains(id), "missing action \(id)")
    }
    XCTAssertEqual(ids.count, Set(ids).count, "action ids must be unique")

    let newEvent = try XCTUnwrap(catalog.actions.first { $0.id == "new-event" })
    XCTAssertEqual(newEvent.supportedSubjectTypes, [.application])
    XCTAssertEqual(newEvent.allowedTargetTypes, [.textSnippet])
    if case .required = newEvent.targetRequirement {
      // Expected.
    } else {
      XCTFail("App-scoped actions must require typed text as target")
    }
  }
}
