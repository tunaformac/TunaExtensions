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

    XCTAssertEqual(url.scheme, "x-fantastical")
    XCTAssertEqual(url.host, "parse")
    XCTAssertEqual(url.query, "sentence=Lunch%20with%20Sam%20friday%2012h30%20%2B1")
  }

  func testParseURLAddsTaskAndAddFlags() throws {
    let url = try XCTUnwrap(
      FantasticalURLBuilder.parseURL(
        sentence: "Call bank", task: true, addImmediately: true, miniWindow: true))

    XCTAssertEqual(url.scheme, "x-fantastical-mini")
    XCTAssertEqual(url.query, "sentence=todo%20Call%20bank&add=1")
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
      "x-fantastical://date/2026-09-17")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .tomorrow, now: now, calendar: calendar)?.absoluteString,
      "x-fantastical://date/2026-09-18")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .calendar)?.absoluteString,
      "x-fantastical://show/calendar")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .miniWindow)?.absoluteString,
      "x-fantastical-mini://show/mini")
    XCTAssertEqual(
      FantasticalURLBuilder.showURL(for: .calendarSet("Work Week"))?.absoluteString,
      "x-fantastical://show/set?name=Work%20Week")
  }

  func testSearchURL() {
    XCTAssertEqual(
      FantasticalURLBuilder.searchURL(query: "dentist", miniWindow: false)?.absoluteString,
      "x-fantastical://search?s=dentist")
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
        "fantastical.new-event", "fantastical.new-task", "fantastical.view.today",
        "fantastical.view.tomorrow", "fantastical.view.calendar", "fantastical.view.mini",
        "fantastical.set.Work",
      ])
    XCTAssertTrue(items.dropFirst(2).allSatisfy { $0.typeID == .fantasticalDestination })
    XCTAssertEqual(items.first?.searchText, "Fantastical New Event")
    XCTAssertEqual(items[2].searchText, "Fantastical Today")
  }

  func testNewEntriesTakeTypedTextThroughTheAddAction() throws {
    let catalog = FantasticalActionsCatalog(
      definition: ActionCatalogDefinition(identifier: FantasticalIdentifiers.actionCatalog, name: "Fantastical"))
    let add = try XCTUnwrap(
      catalog.actions.first { $0.id == FantasticalIdentifiers.addTypedAction } as? PredicateAwareAction)
    XCTAssertEqual(add.targetRequirement, .required)
    XCTAssertEqual(add.allowedTargetTypes, [.textSnippet])

    let task = FantasticalNewItemEntry(task: true)
    XCTAssertTrue(task.isTask)
    XCTAssertEqual(task.typeID, .searchCatalogEntry)
    XCTAssertTrue(task.allowsAction(add, catalogIdentifier: FantasticalIdentifiers.actionCatalog))
    let show = try XCTUnwrap(catalog.actions.first { $0.id == FantasticalIdentifiers.showAction })
    XCTAssertFalse(task.allowsAction(show, catalogIdentifier: FantasticalIdentifiers.actionCatalog))
    XCTAssertTrue(add.subjectPredicate?(task) ?? false)
    XCTAssertFalse(add.subjectPredicate?(FantasticalDestinationItem(destination: .today)) ?? true)
  }

  @MainActor
  func testNewEntryRootsBrowseOnlyMatchingCalendars() {
    FantasticalAgendaSupport.knownCalendars.value = [
      FantasticalCalendar(id: "e", title: "Perso", isWritable: true, supportsEvents: true, supportsTasks: false, sourceName: "iCloud"),
      FantasticalCalendar(id: "t", title: "My Tasks", isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "Google"),
      FantasticalCalendar(id: "r", title: "Holidays", isWritable: false, supportsEvents: true, supportsTasks: false, sourceName: "iCloud"),
    ]
    let tasks = FantasticalNewItemRoot(task: true).hierarchyChildren()
    XCTAssertEqual(tasks.map(\.id), ["fantastical.new-task.t"])
    XCTAssertEqual(tasks.first?.title, "New Task in My Tasks")
    XCTAssertEqual(tasks.first?.detail, "Google")

    let events = FantasticalNewItemRoot(task: false).hierarchyChildren()
    XCTAssertEqual(events.map(\.id), ["fantastical.new-event.e"])
    XCTAssertEqual((events.first as? FantasticalNewItemEntry)?.calendar?.title, "Perso")
    XCTAssertTrue((events.first as? FantasticalNewItemEntry).map { $0.isTask == false } ?? false)
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
      "sentence=todo%20%22Dentist%20visit%22%20Dentist%202026-10-03%2014%3A00%20all%20day%20%2FPerso"
        + "&url=https%3A%2F%2Fx.com&notes=bring%20card")
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
    XCTAssertEqual(items[0].timeZone, TimeZone(identifier: "Europe/Paris"))

    let withoutEnvelope = try FantasticalAgendaParser.items(
      from: #"[{"startDate":"2026-09-23T12:30:00+02:00","id":"c;1","calendarId":"c","title":"Hypno"}]"#)
    XCTAssertEqual(withoutEnvelope.first?.timeZone, TimeZone(secondsFromGMT: 7200))

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

  func testAgendaRangesProduceTheWhenStringsTheHelperAccepts() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.firstWeekday = 2
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    XCTAssertEqual(FantasticalAgendaRange.today.when(now: now, calendar: calendar), "September 18, 2026")
    XCTAssertEqual(FantasticalAgendaRange.tomorrow.when(now: now, calendar: calendar), "September 19, 2026")
    XCTAssertEqual(
      FantasticalAgendaRange.thisWeek.when(now: now, calendar: calendar),
      "September 14, 2026 to September 20, 2026")
    XCTAssertEqual(
      FantasticalAgendaRange.next7Days.when(now: now, calendar: calendar),
      "September 18, 2026 to September 24, 2026")
    XCTAssertEqual(
      FantasticalAgendaRange.thisMonth.when(now: now, calendar: calendar),
      "September 1, 2026 to September 30, 2026")
    XCTAssertEqual(
      FantasticalAgendaRange.thisQuarter.when(now: now, calendar: calendar),
      "July 1, 2026 to September 30, 2026")
    XCTAssertEqual(
      FantasticalAgendaRange.thisYear.when(now: now, calendar: calendar),
      "January 1, 2026 to December 31, 2026")
    XCTAssertTrue(FantasticalAgendaRange.tasks.tasksOnly)
    XCTAssertFalse(FantasticalAgendaRange.queried.contains(.today))
    XCTAssertFalse(FantasticalAgendaRange.queried.contains(.tasks), "task lists are asked one by one")
    XCTAssertEqual(FantasticalAgendaRange.queried.count, 5)

    func item(_ id: String, day: Int?) -> FantasticalAgendaItem {
      let start = day.flatMap { calendar.date(from: DateComponents(year: 2026, month: 9, day: $0, hour: 12)) }
      return FantasticalAgendaItem(id: id, title: id, calendarID: "c", start: start, end: start, location: nil)
    }
    XCTAssertEqual(
      FantasticalAgendaSupport.sorted([item("z", day: nil), item("c", day: 22), item("a", day: 18)]).map(\.id),
      ["a", "c", "z"])
  }

  func testTasksRowNamesTheOverdueShare() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let lists = [
      FantasticalCalendar(
        id: "t", title: "My Tasks", isWritable: true, supportsEvents: false, supportsTasks: true,
        sourceName: "G")
    ]
    let mixed = FantasticalCalendar(
      id: "m", title: "Home", isWritable: true, supportsEvents: true, supportsTasks: true,
      sourceName: "CalDAV")
    let dated = FantasticalAgendaItem(
      id: "d", title: "d", calendarID: "m", start: now, end: now.addingTimeInterval(3600), location: nil)
    let openEnded = FantasticalAgendaItem(
      id: "o", title: "o", calendarID: "m", start: now, end: nil, location: nil)
    XCTAssertFalse(FantasticalAgendaSupport.isTask(dated, in: mixed), "an event always carries an end")
    XCTAssertTrue(FantasticalAgendaSupport.isTask(openEnded, in: mixed), "a task in a mixed calendar has none")
    XCTAssertTrue(FantasticalAgendaSupport.isTask(dated, in: lists[0]), "a task list settles it by itself")
    XCTAssertFalse(FantasticalAgendaSupport.isTask(openEnded, in: nil))

    XCTAssertEqual(
      FantasticalAgendaRange.taskWhen(now: now, calendar: calendar),
      "September 18, 2021 to October 17, 2026", "backlog through the next 30 days, inclusive")

  }

  func testAgendaSortKeepsGroupOrderThenSoonestItems() {
    let today = FantasticalSectionItem(
      title: "Today", id: "t", detail: nil, symbolName: "sun.max", iconColor: .orange, children: [],
      sortOrder: 0)
    let year = FantasticalSectionItem(
      title: "This Year", id: "y", detail: nil, symbolName: "calendar", iconColor: .gray, children: [],
      sortOrder: 6)
    let byCalendar = FantasticalSectionItem(
      title: "By Calendar", id: "b", detail: nil, symbolName: "folder", iconColor: .gray, children: [],
      sortOrder: 7)
    let soon = FantasticalAgendaEntity(
      item: FantasticalAgendaItem(id: "1", title: "Zed", calendarID: "c", start: Date(timeIntervalSinceNow: 3600), end: nil, location: nil),
      calendarTitle: nil, isTask: false)
    let later = FantasticalAgendaEntity(
      item: FantasticalAgendaItem(id: "2", title: "Alpha", calendarID: "c", start: Date(timeIntervalSinceNow: 7200), end: nil, location: nil),
      calendarTitle: nil, isTask: false)
    let sorted = FantasticalAgendaSort.options[0].sort([later, byCalendar, year, soon, today])
    XCTAssertEqual(sorted.map(\.id), ["t", "y", "b", "fantastical.item.1", "fantastical.item.2"])
  }

  func testSectionsAreBuiltPerRangeWithCountsAndCap() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let cals = [
      FantasticalCalendar(id: "e", title: "Perso", isWritable: true, supportsEvents: true, supportsTasks: false, sourceName: "G"),
      FantasticalCalendar(id: "t", title: "Tasks", isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "G"),
      FantasticalCalendar(id: "r", title: "Jours feries", isWritable: false, supportsEvents: true, supportsTasks: false, sourceName: "Subscribed"),
    ]
    func item(_ id: String, cal: String, day: Int) -> FantasticalAgendaItem {
      let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))
      return FantasticalAgendaItem(id: id, title: id, calendarID: cal, start: start, end: start, location: nil)
    }
    let a = item("a", cal: "e", day: 18), b = item("b", cal: "t", day: 19)
    let c = item("c", cal: "r", day: 18)
    let year = (0..<99).map { item("y\($0)", cal: "e", day: 1 + $0 % 28) }
    let sections = FantasticalAgendaSupport.sections(
      from: [.today: [a], .tomorrow: [b], .next7Days: [b, a, c], .thisYear: year],
      calendars: cals,
      taskLists: [FantasticalTaskList(calendar: cals[1], source: .helper, items: [b])],
      now: now, calendar: calendar)
    let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
    XCTAssertEqual(byID["fantastical.agenda.today"]?.detail, "1 item")
    XCTAssertEqual(byID["fantastical.agenda.tasks"]?.detail, "1 open")
    XCTAssertEqual(
      (byID["fantastical.agenda.tasks"] as? FantasticalSectionItem)?.hierarchyChildren().map(\.title), ["Tasks"])
    XCTAssertEqual(byID["fantastical.agenda.thisMonth"]?.detail, "0 items")
    XCTAssertEqual(byID["fantastical.agenda.thisYear"]?.detail, "99+ items, Fantastical returns the first 99")
    XCTAssertEqual(byID["fantastical.agenda.by-calendar"]?.detail, "3 calendars, next 7 days")
    XCTAssertEqual(
      (byID["fantastical.agenda.by-calendar"] as? FantasticalSectionItem)?.hierarchyChildren().map(\.title),
      ["Perso", "Tasks", "Jours feries"], "a read-only calendar still groups its items")
    XCTAssertEqual(
      (byID["fantastical.agenda.next7Days"] as? FantasticalSectionItem)?.hierarchyChildren().map(\.id),
      ["fantastical.item.a", "fantastical.item.c", "fantastical.item.b"])
  }

  func testDayWindowsSplitAtMidnightAndKeepLongItems() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let today = FantasticalAgendaRange.today.interval(now: now, calendar: calendar)
    let tomorrow = FantasticalAgendaRange.tomorrow.interval(now: now, calendar: calendar)

    func at(_ day: Int, _ hour: Int = 0) -> Date? {
      calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))
    }
    func item(_ start: Date?, _ end: Date?) -> FantasticalAgendaItem {
      FantasticalAgendaItem(
        id: "x", title: "x", calendarID: "c", start: start, end: end, location: nil,
        timeZone: calendar.timeZone)
    }

    let startsAtMidnight = item(at(19), at(19, 1))
    XCTAssertFalse(
      startsAtMidnight.overlaps(today, calendar: calendar), "midnight belongs to the day that begins")
    XCTAssertTrue(startsAtMidnight.overlaps(tomorrow, calendar: calendar))

    let endsAtMidnight = item(at(18, 22), at(19))
    XCTAssertTrue(endsAtMidnight.overlaps(today, calendar: calendar))
    XCTAssertFalse(endsAtMidnight.overlaps(tomorrow, calendar: calendar))

    let overnight = item(at(18, 22), at(19, 1))
    XCTAssertTrue(overnight.overlaps(today, calendar: calendar), "an overnight item belongs to both days")
    XCTAssertTrue(overnight.overlaps(tomorrow, calendar: calendar))

    let multiDay = item(at(16), at(24))
    XCTAssertTrue(
      multiDay.overlaps(today, calendar: calendar), "a multi-day item belongs to every day it runs through")
    XCTAssertTrue(multiDay.overlaps(tomorrow, calendar: calendar))

    let allDayToday = item(at(18), at(19))
    XCTAssertTrue(allDayToday.isAllDay(in: calendar))
    XCTAssertTrue(allDayToday.overlaps(today, calendar: calendar))
    XCTAssertFalse(allDayToday.overlaps(tomorrow, calendar: calendar))

    XCTAssertTrue(
      item(at(18, 12), nil).overlaps(today, calendar: calendar), "no end still lands on its own day")
    XCTAssertFalse(item(nil, nil).overlaps(today, calendar: calendar))

    let onlyInTheMonthQuery = item(at(16), at(24))
    let pool = FantasticalAgendaSupport.dayPool(from: [.thisMonth: [onlyInTheMonthQuery], .next7Days: []])
    XCTAssertEqual(
      pool.count, 1, "a running item the seven day query missed still reaches Today and Tomorrow")
  }

  func testAllDayFollowsTheHelperTimezone() throws {
    let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    var tokyoCalendar = Calendar(identifier: .gregorian)
    tokyoCalendar.timeZone = tokyo
    let midnightInTokyo = try XCTUnwrap(
      tokyoCalendar.date(from: DateComponents(year: 2026, month: 9, day: 18)))

    let stamped = FantasticalAgendaItem(
      id: "1", title: "Jour ferie", calendarID: "c", start: midnightInTokyo, end: midnightInTokyo,
      location: nil, timeZone: tokyo)

    var parisCalendar = Calendar(identifier: .gregorian)
    parisCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
    parisCalendar.locale = Locale(identifier: "en_US")

    XCTAssertTrue(
      stamped.isAllDay(in: parisCalendar), "midnight in the helper's zone is all day wherever Tuna runs")
    XCTAssertEqual(stamped.span(in: parisCalendar)?.lowerBound, midnightInTokyo)
    XCTAssertEqual(stamped.span(in: parisCalendar)?.upperBound, midnightInTokyo.addingTimeInterval(86_400))

    // In Paris that instant is still 2026-09-17, so the label must name the helper's day.
    let detail = FantasticalAgendaFormat.detail(
      stamped, calendarTitle: nil, now: midnightInTokyo, calendar: parisCalendar)
    XCTAssertTrue(detail.hasSuffix(", all day"), detail)
    XCTAssertTrue(detail.contains("18") && detail.contains("Sep"), detail)
    XCTAssertFalse(detail.hasPrefix("Today"), "the viewer is still on the 17th: \(detail)")
  }

  func testAllDayItemIsFiledUnderOneDayAcrossZones() throws {
    let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
    var parisCalendar = Calendar(identifier: .gregorian)
    parisCalendar.timeZone = paris
    let holiday = try XCTUnwrap(parisCalendar.date(from: DateComponents(year: 2026, month: 9, day: 19)))
    let item = FantasticalAgendaItem(
      id: "h", title: "Jour ferie", calendarID: "c", start: holiday, end: holiday, location: nil,
      timeZone: paris)

    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
    let today = FantasticalAgendaRange.today.interval(now: now, calendar: losAngeles)
    let tomorrow = FantasticalAgendaRange.tomorrow.interval(now: now, calendar: losAngeles)

    XCTAssertFalse(item.overlaps(today, calendar: losAngeles), "a one day holiday lands on one day")
    XCTAssertTrue(item.overlaps(tomorrow, calendar: losAngeles), "and it is the day Fantastical named")
  }

  func testParserReadsFractionalAndFloatingTimestamps() throws {
    let fractional = try FantasticalAgendaParser.items(
      from: #"{"timezone":"Europe/Paris","items":[{"startDate":"2026-09-19T00:00:00.000Z","id":"a","calendarId":"c","title":"UTC all day"}]}"#)
    let utcItem = try XCTUnwrap(fractional.first)
    XCTAssertNotNil(utcItem.start, "fractional seconds still parse")
    XCTAssertEqual(
      utcItem.timeZone?.secondsFromGMT(for: try XCTUnwrap(utcItem.start)), 0,
      "the offset stamped on the date wins over the envelope")
    XCTAssertTrue(utcItem.isAllDay(in: Calendar(identifier: .gregorian)))

    let floating = try FantasticalAgendaParser.items(
      from: #"{"timezone":"Europe/Paris","items":[{"startDate":"2026-09-19T00:00:00","id":"b","calendarId":"c","title":"Floating"}]}"#)
    XCTAssertNotNil(floating.first?.start, "an offset-less timestamp is read in the helper's zone")
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
    let allDay = FantasticalAgendaItem(
      id: "2", title: "buy cat food", calendarID: "t", start: midnight, end: midnight, location: nil,
      timeZone: calendar.timeZone)
    XCTAssertTrue(allDay.isAllDay(in: calendar))
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
  }

  func testMCPErrorMessagesCarryHelperDetail() {
    XCTAssertEqual(
      FantasticalMCPError.notRunning(detail: nil).errorDescription, "Open Fantastical and try again.")
    XCTAssertEqual(
      FantasticalMCPError.notRunning(detail: "host denied").errorDescription,
      "Fantastical's helper stopped: host denied")
    XCTAssertEqual(FantasticalMCPError.tool("nope").errorDescription, "nope")
  }

  func testLineBufferSplitsChunksIntoCompleteLines() {
    let buffer = LineBuffer()
    XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
    XCTAssertEqual(buffer.append(Data(":2}\n\n".utf8)), ["{\"b\":2}", ""])
    XCTAssertEqual(buffer.append(Data("tail".utf8)), [])
  }

  func testMutatingActionsSkipReadOnlyCalendars() throws {
    let catalog = FantasticalActionsCatalog(
      definition: ActionCatalogDefinition(identifier: FantasticalIdentifiers.actionCatalog, name: "Fantastical"))
    let item = FantasticalAgendaItem(
      id: "1", title: "Jour ferie", calendarID: "r", start: Date(), end: nil, location: nil)
    let readOnly = FantasticalAgendaEntity(
      item: item, calendarTitle: "Jours feries", isTask: false, isEditable: false)
    let editable = FantasticalAgendaEntity(
      item: item, calendarTitle: "Perso", isTask: false, isEditable: true)

    for id in FantasticalActionsCatalog.agendaActionIDs
    where id != "add-to-fantastical-calendar" && id != FantasticalIdentifiers.completeAction
      && id != FantasticalIdentifiers.showAllTasksAction
    {
      let action = try XCTUnwrap(catalog.actions.first { $0.id == id } as? PredicateAwareAction)
      XCTAssertFalse(action.subjectPredicate?(readOnly) ?? true, "\(id) offered on a read-only calendar")
      XCTAssertTrue(action.subjectPredicate?(editable) ?? false, "\(id) missing on a writable calendar")
    }

    let changeLocation = try XCTUnwrap(
      catalog.actions.first { $0.id == "change-location" } as? PredicateAwareAction)
    let task = FantasticalAgendaEntity(item: item, calendarTitle: "My Tasks", isTask: true, isEditable: true)
    XCTAssertFalse(
      changeLocation.subjectPredicate?(task) ?? true, "the helper keeps no location on a task")
    let rename = try XCTUnwrap(catalog.actions.first { $0.id == "rename" } as? PredicateAwareAction)
    XCTAssertTrue(rename.subjectPredicate?(task) ?? false, "a task can still be renamed")

    let calendars = [
      FantasticalCalendar(
        id: "r", title: "Jours feries", isWritable: false, supportsEvents: true, supportsTasks: false,
        sourceName: "Subscribed")
    ]
    XCTAssertFalse(
      FantasticalAgendaSupport.entity(for: item, calendars: calendars, now: Date()).isEditable)
    XCTAssertTrue(
      FantasticalAgendaSupport.entity(for: item, calendars: [], now: Date()).isEditable,
      "an item Tuna cannot match keeps its actions")
  }

  @MainActor
  func testOpenSectionAsksForARebuildAfterAWrite() {
    final class Counter { var value = 0 }
    let counter = Counter()
    let section = FantasticalSectionItem(
      title: "Today", id: "t", detail: nil, symbolName: "sun.max", iconColor: .orange, children: [],
      sortOrder: 0)
    let observer = NotificationCenter.default.addObserver(
      forName: CatalogDidFinishScan, object: nil, queue: nil
    ) { _ in counter.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    _ = section.hierarchyChildren()
    XCTAssertEqual(counter.value, 0, "a fresh section asks for nothing")

    FantasticalAgendaSupport.postDataDidChange()
    _ = section.hierarchyChildren()
    XCTAssertEqual(counter.value, 1, "a section built before the write asks the host to rebuild it")
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

  func testAlertsRepeatInTheSentenceBeforeTheCalendar() throws {
    let fields = try FantasticalFields.parse(
      "Dentist tomorrow 15h -- alert: 30 minutes -- alarm: 1 day before at 9am -- cal: Perso").get()
    XCTAssertEqual(fields.alerts, ["30 minutes", "1 day before at 9am"])
    XCTAssertEqual(
      FantasticalURLBuilder.sentence(for: fields, task: false),
      "Dentist tomorrow 15h alert 30 minutes alert 1 day before at 9am /Perso")
  }

  func testAddToCalendarUsesTheParseURLWithThePickedCalendar() throws {
    let fields = try FantasticalFields.parse("buy printer paper -- due: next friday -- cal: Perso").get()
    let tasks = FantasticalCalendar(
      id: "t", title: "My Tasks", isWritable: true, supportsEvents: false, supportsTasks: true, sourceName: "")
    let taskURL = try XCTUnwrap(
      FantasticalActions.parseURL(fields: fields, calendar: tasks, addImmediately: false, miniWindow: false))
    XCTAssertEqual(
      taskURL.query, "sentence=todo%20buy%20printer%20paper%20next%20friday%20%2FMy%20Tasks")

    let events = FantasticalCalendar(
      id: "e", title: "Perso", isWritable: true, supportsEvents: true, supportsTasks: false, sourceName: "")
    let eventURL = try XCTUnwrap(
      FantasticalActions.parseURL(
        fields: try FantasticalFields.parse("Lunch friday 12h30").get(), calendar: events,
        addImmediately: true, miniWindow: true))
    XCTAssertEqual(eventURL.query, "sentence=Lunch%20friday%2012h30%20%2FPerso&add=1")
  }

  @MainActor
  func testCalendarsCatalogIsHiddenTargetPlumbing() throws {
    let instance = try FantasticalExtension(bundle: Bundle(for: FantasticalExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()
    let calendars = try XCTUnwrap(
      declaration.catalogs.first { $0.id == FantasticalIdentifiers.calendarsCatalog })
    XCTAssertEqual(calendars.presentation, .hidden)
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

    let mini = try XCTUnwrap(
      catalog.actions.first { $0.id == FantasticalIdentifiers.miniWindowAction }
        as? PredicateAwareAction)
    XCTAssertEqual(mini.supportedSubjectTypes, [.application])
    XCTAssertFalse(
      mini.subjectPredicate?(FantasticalDestinationItem(destination: .today)) ?? true,
      "the app action is offered on Fantastical.app, not on a view")
    XCTAssertEqual(ids.count, Set(ids).count, "action ids must be unique")

    let add = try XCTUnwrap(catalog.actions.first { $0.id == "add-to-fantastical" })
    XCTAssertEqual(add.supportedSubjectTypes, [.textSnippet, .url])
    let show = try XCTUnwrap(catalog.actions.first { $0.id == FantasticalIdentifiers.showAction })
    XCTAssertEqual(show.supportedSubjectTypes, [.fantasticalDestination, .fantasticalItem])
  }

  func testAllDayCoversBothHelperShapes() throws {
    let calendar = Calendar.autoupdatingCurrent
    let midnight = calendar.startOfDay(for: Date())
    let nextMidnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: midnight))

    func item(start: Date?, end: Date?) -> FantasticalAgendaItem {
      FantasticalAgendaItem(id: "x", title: "x", calendarID: "c", start: start, end: end, location: nil)
    }

    XCTAssertTrue(item(start: midnight, end: midnight).isAllDay, "one midnight instant")
    XCTAssertTrue(item(start: midnight, end: nextMidnight).isAllDay, "midnight through next midnight")
    XCTAssertTrue(item(start: midnight, end: nil).isAllDay, "midnight with no end")
    XCTAssertFalse(item(start: midnight.addingTimeInterval(3600), end: nil).isAllDay, "timed start, no end")
    XCTAssertFalse(item(start: midnight.addingTimeInterval(3600), end: nextMidnight).isAllDay)
    XCTAssertFalse(item(start: nil, end: nil).isAllDay, "undated")
  }

  @MainActor func testCalendarsCatalogScanKeepsOnlyWritableCalendars() async {
    let catalog = FantasticalCalendarsCatalog(
      definition: CatalogDefinition(
        identifier: FantasticalIdentifiers.calendarsCatalog, name: "Fantastical Calendars",
        enabledByDefault: true, settings: []))
    catalog.loadCalendars = {
      [
        FantasticalCalendar(
          id: "1", title: "Perso", isWritable: true, supportsEvents: true, supportsTasks: false,
          sourceName: "iCloud"),
        FantasticalCalendar(
          id: "2", title: "Jours feries", isWritable: false, supportsEvents: true,
          supportsTasks: false, sourceName: "Subscribed"),
      ]
    }

    await catalog.scan()

    XCTAssertEqual(catalog.objects.map(\.title), ["Perso"])
  }

  @MainActor func testCalendarsCatalogScanExplainsAnEmptyResult() async {
    let catalog = FantasticalCalendarsCatalog(
      definition: CatalogDefinition(
        identifier: FantasticalIdentifiers.calendarsCatalog, name: "Fantastical Calendars",
        enabledByDefault: true, settings: []))
    catalog.loadCalendars = { [] }

    await catalog.scan()

    XCTAssertEqual(catalog.objects.map(\.title), ["No Writable Calendars"])
  }
}
