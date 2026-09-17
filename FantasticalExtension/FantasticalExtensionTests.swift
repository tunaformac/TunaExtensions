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

  func testFieldsParseSentenceOnly() throws {
    let fields = try FantasticalFields.parse("Dentist tomorrow 15h").get()
    XCTAssertEqual(fields.sentence, "Dentist tomorrow 15h")
    XCTAssertNil(fields.title)
    XCTAssertFalse(fields.allDay)
  }

  func testFieldsParseEveryKeyAndKeepsSeparatorInsideURLs() throws {
    let text =
      "Dentist tomorrow 15h -- title: Dentist visit -- start: 2026-10-03 14:00 -- end: 2026-10-03 15:00"
      + " -- due: friday -- allday -- cal: Perso -- url: https://x.com/a--b -- notes: bring card"
    let fields = try FantasticalFields.parse(text).get()

    XCTAssertEqual(fields.sentence, "Dentist tomorrow 15h")
    XCTAssertEqual(fields.title, "Dentist visit")
    XCTAssertEqual(fields.start, "2026-10-03 14:00")
    XCTAssertEqual(fields.end, "2026-10-03 15:00")
    XCTAssertEqual(fields.due, "friday")
    XCTAssertTrue(fields.allDay)
    XCTAssertEqual(fields.calendarName, "Perso")
    XCTAssertEqual(fields.url, "https://x.com/a--b")
    XCTAssertEqual(fields.notes, "bring card")
  }

  func testFieldsAcceptSynonymsAndAnyCase() throws {
    let fields = try FantasticalFields.parse(
      "x -- Note: hi -- LINK: https://y -- From: 9h -- To: 10h -- Calendar: Work -- All-Day: no"
    ).get()
    XCTAssertEqual(fields.notes, "hi")
    XCTAssertEqual(fields.url, "https://y")
    XCTAssertEqual(fields.start, "9h")
    XCTAssertEqual(fields.end, "10h")
    XCTAssertEqual(fields.calendarName, "Work")
    XCTAssertFalse(fields.allDay)
  }

  func testFieldsUseTheConfiguredSeparator() throws {
    let fields = try FantasticalFields.parse("Call Sam -- not a field >> notes: hi", separator: ">>").get()
    XCTAssertEqual(fields.sentence, "Call Sam -- not a field")
    XCTAssertEqual(fields.notes, "hi")
  }

  func testFieldsTitleOnlyWithoutSentence() throws {
    let fields = try FantasticalFields.parse("-- title: Exact -- start: 2026-10-03").get()
    XCTAssertNil(fields.sentence)
    XCTAssertEqual(fields.title, "Exact")
    XCTAssertEqual(fields.start, "2026-10-03")
  }

  func testFieldsRejectUnknownKeysMissingValuesAndEmptyText() {
    XCTAssertEqual(
      FantasticalFields.parse("x -- nots: y"), .failure(.unknownField("nots")))
    XCTAssertEqual(
      FantasticalFields.parse("x -- notes:"), .failure(.missingValue("notes")))
    XCTAssertEqual(FantasticalFields.parse("   "), .failure(.empty))
    XCTAssertEqual(FantasticalFields.parse("-- allday"), .failure(.empty))
  }

  func testParseURLEncodesEveryField() throws {
    var fields = FantasticalFields()
    fields.sentence = "Dentist"
    fields.title = "Dentist visit"
    fields.start = "2026-10-03 14:00"
    fields.allDay = true
    fields.calendarName = "Perso"
    fields.url = "https://x.com"
    fields.notes = "bring card"
    let url = try XCTUnwrap(
      FantasticalURLBuilder.parseURL(
        fields: fields, task: true, addImmediately: false, miniWindow: false))

    XCTAssertEqual(
      url.query,
      "sentence=Dentist&title=Dentist%20visit&start=2026-10-03%2014%3A00&calendarName=Perso"
        + "&url=https%3A%2F%2Fx.com&notes=bring%20card&allDay=1&task=1")
  }

  func testLinkItemsBecomeSentencePlusURL() throws {
    let link = URLItem(urlString: "https://example.com/page")
    let fields = try FantasticalActions.fields(for: link)
    XCTAssertEqual(fields.url, "https://example.com/page")
    XCTAssertNotNil(fields.sentence)
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

    let add = try XCTUnwrap(catalog.actions.first { $0.id == "add-to-fantastical" })
    XCTAssertEqual(add.supportedSubjectTypes, [.textSnippet, .url])

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
