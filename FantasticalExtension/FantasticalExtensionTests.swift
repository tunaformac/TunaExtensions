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

  func testFieldsAcceptSmartDashesForTheDoubleHyphenSeparator() throws {
    let emDash = try FantasticalFields.parse("dentist tomorrow \u{2014} notes: testing").get()
    XCTAssertEqual(emDash.sentence, "dentist tomorrow")
    XCTAssertEqual(emDash.notes, "testing")

    let enDash = try FantasticalFields.parse("dentist tomorrow \u{2013} cal: Perso").get()
    XCTAssertEqual(enDash.calendarName, "Perso")

    let custom = try FantasticalFields.parse("a \u{2014} notes: x", separator: ">>").get()
    XCTAssertEqual(custom.sentence, "a \u{2014} notes: x")
    XCTAssertNil(custom.notes)
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

  func testAgendaParserReadsCalendarsAndItems() throws {
    let calendars = try FantasticalAgendaParser.calendars(
      from: #"[{"title":"Perso","isWritable":true,"supportsEvents":true,"sourceName":"Google","supportsTasks":false,"id":"cal1"}]"#)
    XCTAssertEqual(calendars.count, 1)
    XCTAssertEqual(calendars.first?.title, "Perso")
    XCTAssertTrue(calendars.first?.supportsEvents == true)

    let items = try FantasticalAgendaParser.items(
      from: #"{"timezone":"Europe/Paris","items":[{"startDate":"2026-09-23T12:30:00+02:00","endDate":"2026-09-23T13:30:00+02:00","id":"cal1;abc","calendarId":"cal1","title":"Hypno","location":"Lyon"},{"id":"cal2;task","title":"buy cat food","calendarId":"cal2"}]}"#)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].location, "Lyon")
    XCTAssertNotNil(items[0].start)
    XCTAssertNil(items[1].start)
    XCTAssertEqual(items[1].calendarID, "cal2")

    XCTAssertEqual(try FantasticalAgendaParser.items(from: "No results found."), [])
    XCTAssertThrowsError(try FantasticalAgendaParser.items(from: "not json"))
  }

  func testWhenRangesUseTheSpellingFantasticalAccepts() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
    XCTAssertEqual(
      FantasticalWhen.range(from: start, to: end, calendar: calendar),
      "September 18, 2026 to September 25, 2026")
  }

  func testAgendaBucketsAndSorting() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    func item(_ id: String, dayOffset: Int?, hour: Int = 12) -> FantasticalAgendaItem {
      let start = dayOffset.flatMap { calendar.date(byAdding: .day, value: $0, to: now) }
        .flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
      return FantasticalAgendaItem(id: id, title: id, calendarID: "c", start: start, end: start, location: nil)
    }
    XCTAssertEqual(FantasticalAgendaBucket.bucket(for: item("a", dayOffset: 0), now: now, calendar: calendar), .today)
    XCTAssertEqual(FantasticalAgendaBucket.bucket(for: item("b", dayOffset: 1), now: now, calendar: calendar), .tomorrow)
    XCTAssertEqual(FantasticalAgendaBucket.bucket(for: item("c", dayOffset: 4), now: now, calendar: calendar), .week)
    XCTAssertNil(FantasticalAgendaBucket.bucket(for: item("d", dayOffset: -2), now: now, calendar: calendar))
    XCTAssertNil(FantasticalAgendaBucket.bucket(for: item("e", dayOffset: nil), now: now, calendar: calendar))

    let sorted = FantasticalAgendaSupport.sorted([item("z", dayOffset: nil), item("c", dayOffset: 4), item("a", dayOffset: 0)])
    XCTAssertEqual(sorted.map(\.id), ["a", "c", "z"])
  }

  func testAgendaDetailFormatting() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.locale = Locale(identifier: "en_US")
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12, minute: 30)))
    let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 13, minute: 30)))
    let timed = FantasticalAgendaItem(id: "1", title: "Hypno", calendarID: "c", start: start, end: end, location: "Lyon")
    let detail = FantasticalAgendaFormat.detail(timed, calendarTitle: "Perso", now: now, calendar: calendar)
    XCTAssertTrue(detail.contains("Sep 23") || detail.contains("23 Sep"), detail)
    XCTAssertTrue(detail.hasSuffix("Perso · Lyon"), detail)

    let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18)))
    let allDay = FantasticalAgendaItem(id: "2", title: "buy cat food", calendarID: "t", start: midnight, end: midnight, location: nil)
    XCTAssertTrue(allDay.isAllDay)
    XCTAssertEqual(FantasticalAgendaFormat.detail(allDay, calendarTitle: nil, now: now, calendar: calendar), "Today, all day")

    let undated = FantasticalAgendaItem(id: "3", title: "x", calendarID: "t", start: nil, end: nil, location: nil)
    XCTAssertEqual(FantasticalAgendaFormat.detail(undated, calendarTitle: "My Tasks", now: now, calendar: calendar), "No date · My Tasks")
  }

  func testMCPRequestsAreJSONRPC() throws {
    let request = FantasticalMCPClient.makeRequest(id: 7, method: "tools/call", params: ["name": "queryCalendars"])
    XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(request["id"] as? Int, 7)
    XCTAssertEqual(request["method"] as? String, "tools/call")
    XCTAssertNil(FantasticalMCPClient.makeRequest(id: nil, method: "notifications/initialized", params: [:])["id"])
    XCTAssertEqual(
      FantasticalAgendaActions.itemType(for: FantasticalCalendar(id: "t", title: "Tasks", isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "")),
      "task")
  }

  func testAgendaActionGrammar() throws {
    let catalog = FantasticalActionsCatalog(
      definition: ActionCatalogDefinition(identifier: FantasticalIdentifiers.actionCatalog, name: "Fantastical"))
    for id in FantasticalActionsCatalog.agendaActionIDs {
      XCTAssertNotNil(catalog.actions.first { $0.id == id }, "missing \(id)")
    }
    let reschedule = try XCTUnwrap(catalog.actions.first { $0.id == "reschedule" })
    XCTAssertEqual(reschedule.supportedSubjectTypes, [.fantasticalItem])
    XCTAssertEqual(reschedule.allowedTargetTypes, [.textSnippet])

    let addToCalendar = try XCTUnwrap(catalog.actions.first { $0.id == "add-to-fantastical-calendar" })
    XCTAssertEqual(addToCalendar.allowedTargetTypes, [.fantasticalCalendar])
    XCTAssertEqual(
      addToCalendar.targetSearchScope,
      .catalogs([FantasticalIdentifiers.calendarsCatalog], preparation: .refresh))
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
