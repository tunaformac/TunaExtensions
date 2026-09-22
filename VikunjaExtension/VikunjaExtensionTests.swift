import Foundation
import TunaKit
import XCTest

@testable import TunaVikunja

@MainActor
final class VikunjaExtensionTests: XCTestCase {
  // MARK: Declaration

  func testDeclarationDeclaresStableIdentifiers() throws {
    let bundle = Bundle(for: VikunjaExtension.self)
    let ext = try VikunjaExtension(bundle: bundle)
    let declaration = try XCTUnwrap(ext.declaration)

    XCTAssertEqual(declaration.catalogs.map(\.id), ["vikunja", "vikunja.projects"])
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["vikunja.actions"])
    XCTAssertEqual(declaration.catalogs[0].presentation, .liveSearch)
    XCTAssertEqual(declaration.catalogs[1].presentation, .source)
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.96")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.22.0")
    XCTAssertEqual(declaration.settings.map(\.key), ["DefaultProject"])
    XCTAssertEqual(
      Set(declaration.typeRegistrations.map(\.typeID)), [.vikunjaTask, .vikunjaProject])
    XCTAssertTrue(declaration.typeRegistrations.allSatisfy { $0.inheritsFrom == [.entity] })
    XCTAssertEqual(declaration.defaultActionRankings.map(\.typeID), [.vikunjaTask, .vikunjaProject])
    XCTAssertEqual(ext.connectionDefinitions.map(\.providerIdentifier), ["vikunja"])
    XCTAssertTrue(ext.connectionDefinitions[0].supportsBaseURL)
    XCTAssertEqual(ext.connectionDefinitions[0].kind, .secret)
  }

  // MARK: Server configuration

  func testServerConfigurationNormalizesBareHost() throws {
    let server = try VikunjaServerConfiguration(baseURLString: "tasks.example.com/")
    XCTAssertEqual(server.webBaseURL.absoluteString, "https://tasks.example.com")
    XCTAssertEqual(server.apiBaseURL.absoluteString, "https://tasks.example.com/api/v1")
    XCTAssertEqual(server.taskURL(id: 42).absoluteString, "https://tasks.example.com/tasks/42")
    XCTAssertEqual(server.projectURL(id: 3).absoluteString, "https://tasks.example.com/projects/3")
  }

  func testServerConfigurationStripsAPIPathAndSubpaths() throws {
    let server = try VikunjaServerConfiguration(baseURLString: "https://host.tld/vikunja/api/v1/")
    XCTAssertEqual(server.webBaseURL.absoluteString, "https://host.tld/vikunja")
    XCTAssertEqual(server.apiBaseURL.absoluteString, "https://host.tld/vikunja/api/v1")
  }

  func testServerConfigurationRejectsMissingOrInvalidURLs() {
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "   ")) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .missingServerURL)
    }
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "ftp://host")) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .invalidServerURL)
    }
  }

  func testServerConfigurationRefusesPlainHTTPExceptLoopback() throws {
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "http://tasks.example.com")) {
      error in
      XCTAssertEqual(error as? VikunjaAPIError, .insecureServerURL)
    }
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "HTTP://192.168.1.5:3456")) {
      error in
      XCTAssertEqual(error as? VikunjaAPIError, .insecureServerURL)
    }
    for local in ["http://localhost:3456", "http://127.0.0.1:3456", "http://[::1]:3456"] {
      XCTAssertNoThrow(try VikunjaServerConfiguration(baseURLString: local), local)
    }
  }

  // MARK: Parsing

  func testParseTaskHandlesNullDatesLabelsAndPriority() throws {
    let json = """
      {"id": 97, "title": "Set up Darktable", "done": false, "due_date": "2026-07-31T09:00:00-07:00",
       "priority": 3, "project_id": 2, "identifier": "#1", "description": "",
       "labels": [{"id": 1, "title": "@home", "hex_color": "ffbe0b"}],
       "done_at": "0001-01-01T00:00:00Z", "updated": "2026-08-18T06:34:44-07:00"}
      """
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let task = try XCTUnwrap(VikunjaAPIClient.parseTask(payload))

    XCTAssertEqual(task.id, 97)
    XCTAssertEqual(task.priorityName, "High")
    XCTAssertEqual(task.labels.map(\.title), ["@home"])
    XCTAssertNotNil(task.dueDate)
    XCTAssertNotNil(task.updatedAt)
    XCTAssertNil(VikunjaAPIClient.parseDate("0001-01-01T00:00:00Z"))
    XCTAssertNil(VikunjaAPIClient.parseDate(nil))
  }

  func testParseProjectSkipsNothingButFetchFiltersArchivedAndPseudoProjects() throws {
    let payload: [String: Any] = [
      "id": -1, "title": "Favorites", "is_archived": false, "parent_project_id": 0,
    ]
    let project = try XCTUnwrap(VikunjaAPIClient.parseProject(payload))
    XCTAssertEqual(project.id, -1)
    XCTAssertEqual(project.hexColor, "")
  }

  func testErrorMapping() {
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 401, data: Data()), .invalidToken)
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 403, data: Data()), .missingScope)
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 404, data: Data()), .notFound)
    XCTAssertEqual(
      VikunjaAPIClient.mapError(status: 500, data: Data(#"{"message":"boom"}"#.utf8)),
      .unexpectedStatus(500, "boom"))
  }

  // MARK: Grouping and formatting

  func testDueBucketsAndSorting() {
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let overdue = makeTask(id: 1, title: "b", due: calendar.date(byAdding: .day, value: -3, to: now))
    let today = makeTask(id: 2, title: "a", due: now)
    let soon = makeTask(id: 3, title: "c", due: calendar.date(byAdding: .day, value: 3, to: now))
    let later = makeTask(id: 4, title: "d", due: calendar.date(byAdding: .day, value: 30, to: now))
    let undatedLow = makeTask(id: 5, title: "z", due: nil, priority: 1)
    let undatedHigh = makeTask(id: 6, title: "y", due: nil, priority: 4)

    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: overdue, now: now), .overdue)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: today, now: now), .today)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: soon, now: now), .upcoming)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: later, now: now), .later)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: undatedLow, now: now), .undated)

    let sorted = VikunjaCatalogSupport.sortedByDue(
      [undatedLow, later, undatedHigh, soon, today, overdue])
    XCTAssertEqual(sorted.map(\.id), [1, 2, 3, 4, 6, 5])
  }

  func testTaskDetailMentionsProjectDueAndLabels() {
    let task = makeTask(id: 1, title: "t", due: Date(), priority: 5, labels: ["@home", "@agent"])
    let detail = VikunjaCatalogSupport.taskDetail(
      task, projectTitle: "Inbox", connection: nil, totalConnections: 1)
    XCTAssertEqual(detail, "Inbox · Due today · Do now · @home @agent")
  }

  func testResolveDefaultProjectPrefersIDThenTitleThenInbox() {
    let projects = [
      VikunjaProject(
        id: 1, title: "Inbox", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 7, title: "Work", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
    ]
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "#7")?.id, 7)
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "work")?.id, 7)
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "nope")?.id, 1)
    XCTAssertNil(VikunjaCatalogSupport.resolveDefaultProject([], preference: "Inbox"))
  }

  func testProjectPathFollowsParents() {
    let home = VikunjaProject(
      id: 2, title: "Home", description: "", parentProjectID: 0, hexColor: "",
      isArchived: false, isFavorite: false)
    let ha = VikunjaProject(
      id: 3, title: "Home assistant", description: "", parentProjectID: 2, hexColor: "01c7fc",
      isArchived: false, isFavorite: false)
    XCTAssertEqual(VikunjaCatalogSupport.projectPath(ha, in: [home, ha]), "Home › Home assistant")
    XCTAssertEqual(VikunjaCatalogSupport.projectPath(home, in: [home, ha]), "Home")
  }

  func testIconColorMapping() {
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "01c7fc"), .teal)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "#2ecc71"), .green)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "ff0000"), .red)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: ""), .blue)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "808080"), .gray)
  }

  // MARK: Catalog shapes

  func testProjectItemsNestChildrenUnderParents() throws {
    let record = ExtensionConnectionRecord(
      providerIdentifier: "vikunja", displayName: "Test", baseURLString: "https://v.example")
    let connection = VikunjaConnection(record: record, accessToken: "token")
    let projects = [
      VikunjaProject(
        id: 2, title: "Home", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 3, title: "Home assistant", description: "", parentProjectID: 2, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 1, title: "Inbox", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
    ]
    let (all, roots) = VikunjaProjectsCatalog.makeProjectItems(
      projects,
      connection: connection,
      server: try VikunjaServerConfiguration(baseURLString: "https://v.example"),
      catalogIdentifier: "vikunja.projects"
    )

    XCTAssertEqual(all.count, 3)
    XCTAssertEqual(roots.map(\.title), ["Home", "Inbox"])
    XCTAssertEqual(all.map(\.id), [
      "vikunja.project.\(record.id).2",
      "vikunja.project.\(record.id).3",
      "vikunja.project.\(record.id).1",
    ])
    XCTAssertTrue(all.allSatisfy { $0.typeID == .vikunjaProject })
    XCTAssertEqual(all[0].path, "https://v.example/projects/2")

    let (aliased, _) = VikunjaProjectsCatalog.makeProjectItems(
      projects,
      connection: connection,
      server: try VikunjaServerConfiguration(baseURLString: "https://v.example"),
      catalogIdentifier: "vikunja",
      idPrefix: "vikunja.tasks.project"
    )
    XCTAssertEqual(aliased[0].id, "vikunja.tasks.project.\(record.id).2")
  }

  func testTasksCatalogExposesRootAndNewTaskEntry() {
    let catalog = VikunjaTasksCatalog(
      definition: CatalogDefinition(
        identifier: "vikunja", name: "Vikunja", enabledByDefault: true,
        presentation: .liveSearch, settings: []))
    XCTAssertFalse(catalog.scansOnStartup)
    XCTAssertEqual(catalog.objects.map(\.id), ["vikunja", "vikunja.new"])
    XCTAssertEqual(catalog.objects[1].typeID, .searchCatalogEntry)
  }

  // MARK: Actions

  func testActionGrammar() throws {
    let catalog = VikunjaActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "vikunja.actions", name: "Vikunja"))
    XCTAssertEqual(
      catalog.actions.map(\.id),
      ["open-task", "open-project", "mark-done", "add-task", "add-task-to-project", "to"])

    let addToProject = try XCTUnwrap(catalog.actions.first { $0.id == "add-task-to-project" })
    XCTAssertNotNil(addToProject.batchCallback)
    XCTAssertEqual(addToProject.supportedSubjectTypes, [.textSnippet])
    XCTAssertEqual(addToProject.allowedTargetTypes, [.vikunjaProject])
    XCTAssertEqual(
      addToProject.targetSearchScope, .catalogs(["vikunja.projects"], preparation: .refresh))
    if case .required = addToProject.targetRequirement {} else {
      XCTFail("Add to Vikunja Project must require a target")
    }

    let markDone = try XCTUnwrap(catalog.actions.first { $0.id == "mark-done" } as? PredicateAwareAction)
    XCTAssertEqual(markDone.supportedSubjectTypes, [.vikunjaTask])
    let openTask = makeTaskItem(makeTask(id: 1, title: "open", due: nil))
    let doneTask = makeTaskItem(makeTask(id: 2, title: "done", due: nil, done: true))
    XCTAssertTrue(markDone.subjectPredicate?(openTask) ?? false)
    XCTAssertFalse(markDone.subjectPredicate?(doneTask) ?? true)

    let toAction = try XCTUnwrap(catalog.actions.first { $0.id == "to" } as? PredicateAwareAction)
    XCTAssertTrue(toAction.subjectPredicate?(VikunjaNewTaskItem()) ?? false)
    XCTAssertFalse(toAction.subjectPredicate?(openTask) ?? true)
    XCTAssertTrue(toAction.targetPredicate?(TextSnippetItem(text: "Buy milk")) ?? false)
    XCTAssertFalse(toAction.targetPredicate?(TextSnippetItem(text: "   ")) ?? true)

    let newTask = VikunjaNewTaskItem()
    XCTAssertTrue(newTask.allowsAction(toAction, catalogIdentifier: "vikunja.actions"))
    XCTAssertFalse(newTask.allowsAction(markDone, catalogIdentifier: "vikunja.actions"))
  }

  func testTaskItemIdentityTypeAndSearchKeys() {
    let item = makeTaskItem(makeTask(id: 12, title: "Buy milk", due: nil, labels: ["@errands"]))
    XCTAssertEqual(item.id, "vikunja.task.conn.12")
    XCTAssertEqual(item.typeID, .vikunjaTask)
    XCTAssertEqual(item.path, "https://v.example/tasks/12")
    XCTAssertFalse(item is TextValueProviding, "tasks show an icon card, not a text card")
    XCTAssertEqual(item.copyRepresentation, "https://v.example/tasks/12")
    XCTAssertEqual(item.searchKeys, ["Buy milk", "Inbox", "@errands", "#12"])
  }

  // MARK: Helpers

  private func makeTask(
    id: Int, title: String, due: Date?, priority: Int = 0, labels: [String] = [],
    done: Bool = false
  ) -> VikunjaTask {
    VikunjaTask(
      id: id, title: title, description: "", done: done, dueDate: due, priority: priority,
      projectID: 1, identifier: "#\(id)",
      labels: labels.enumerated().map { VikunjaLabel(id: $0.offset, title: $0.element, hexColor: "") },
      updatedAt: nil)
  }

  private func makeTaskItem(_ task: VikunjaTask) -> VikunjaTaskItem {
    VikunjaTaskItem(
      task: task, connectionID: "conn", projectTitle: "Inbox",
      url: URL(string: "https://v.example/tasks/\(task.id)")!,
      detail: "Inbox")
  }
}

@MainActor
final class VikunjaSortTests: XCTestCase {
  func testDueSortPutsSectionsFirstThenTasksByDueThenOthers() {
    let now = Date()
    let later = VikunjaSectionItem(
      title: "Later", id: "s.later", detail: nil, symbolName: "clock", iconColor: .gray,
      children: [], sortOrder: 3)
    let overdue = VikunjaSectionItem(
      title: "Overdue", id: "s.overdue", detail: nil, symbolName: "exclamationmark.circle",
      iconColor: .red, children: [], sortOrder: 0)
    let soon = VikunjaTaskItem(
      task: VikunjaTask(
        id: 1, title: "z soon", description: "", done: false, dueDate: now, priority: 0,
        projectID: 1, identifier: "", labels: [], updatedAt: nil),
      connectionID: "c", projectTitle: nil, url: URL(string: "https://v/tasks/1")!, detail: "")
    let undated = VikunjaTaskItem(
      task: VikunjaTask(
        id: 2, title: "a undated", description: "", done: false, dueDate: nil, priority: 0,
        projectID: 1, identifier: "", labels: [], updatedAt: nil),
      connectionID: "c", projectTitle: nil, url: URL(string: "https://v/tasks/2")!, detail: "")
    let message = CatalogMessageItem(
      title: "Empty", message: "", symbolName: "tray", tintColor: .gray)

    let sorted = VikunjaSort.options[0].sort([message, undated, later, soon, overdue])
    XCTAssertEqual(sorted.map(\.id), ["s.overdue", "s.later", "vikunja.task.c.1", "vikunja.task.c.2", message.id])
  }

  func testTaskTimestampsMirrorDueDatesSoSoonestSortsNewest() {
    let now = Date()
    let soon = VikunjaSort.timestamp(forDueDate: now)
    let later = VikunjaSort.timestamp(forDueDate: now.addingTimeInterval(86_400))
    let undated = VikunjaSort.timestamp(forDueDate: nil)
    XCTAssertGreaterThan(soon, later)
    XCTAssertGreaterThan(later, undated)
    XCTAssertEqual(undated, .distantPast)
  }

  func testSortScoresOrderSectionsThenSoonestTasksThenUndatedByPriority() {
    let now = Date()
    let section = VikunjaSort.sectionScoreBase - 3
    let soon = VikunjaSort.score(forDueDate: now, priority: 0)
    let later = VikunjaSort.score(forDueDate: now.addingTimeInterval(86_400), priority: 5)
    let undatedHigh = VikunjaSort.score(forDueDate: nil, priority: 4)
    let undatedLow = VikunjaSort.score(forDueDate: nil, priority: 0)
    XCTAssertGreaterThan(section, soon)
    XCTAssertGreaterThan(soon, later)
    XCTAssertGreaterThan(later, undatedHigh)
    XCTAssertGreaterThan(undatedHigh, undatedLow)
  }
}

// MARK: - Networking

/// Serves canned responses keyed by request path + page so the client can be tested offline.
final class VikunjaStubProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let (status, headers, data) = handler(request)
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VikunjaStubProtocol.self]
    return URLSession(configuration: configuration)
  }
}

final class VikunjaNetworkingTests: XCTestCase {
  override func tearDown() {
    VikunjaStubProtocol.handler = nil
    super.tearDown()
  }

  private static func tasksPage(_ page: Int, count: Int) -> Data {
    let tasks = (0..<count).map { ["id": page * 1000 + $0, "title": "Task \($0)"] as [String: Any] }
    return try! JSONSerialization.data(withJSONObject: tasks)
  }

  private static func page(of request: URLRequest) -> Int {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
  }

  private func makeClient(host: String = "tasks.example.com") throws -> VikunjaAPIClient {
    VikunjaAPIClient(
      server: try VikunjaServerConfiguration(baseURLString: "https://\(host)"),
      token: "token", session: VikunjaStubProtocol.session())
  }

  func testTaskListingReportsTruncationPastPageLimit() async throws {
    let perPage = VikunjaAPIClient.perPage
    VikunjaStubProtocol.handler = { request in
      (200, ["x-pagination-total-pages": "20"], Self.tasksPage(Self.page(of: request), count: perPage))
    }
    let listing = try await makeClient().fetchOpenTasks()
    XCTAssertTrue(listing.isTruncated)
    XCTAssertEqual(listing.tasks.count, perPage * VikunjaAPIClient.maxTaskPages)

    let search = try await makeClient().searchOpenTasks(query: "x")
    XCTAssertTrue(search.isTruncated)
    XCTAssertEqual(search.tasks.count, perPage * VikunjaAPIClient.maxSearchPages)
  }

  func testTaskListingEndingOnLastPageIsComplete() async throws {
    let perPage = VikunjaAPIClient.perPage
    let pages = VikunjaAPIClient.maxTaskPages
    VikunjaStubProtocol.handler = { request in
      (200, ["x-pagination-total-pages": "\(pages)"], Self.tasksPage(Self.page(of: request), count: perPage))
    }
    let listing = try await makeClient().fetchOpenTasks()
    XCTAssertFalse(listing.isTruncated)
    XCTAssertEqual(listing.tasks.count, perPage * pages)
  }

  func testProjectsAreFetchedPastTheTaskPageLimit() async throws {
    let perPage = VikunjaAPIClient.perPage
    let pages = VikunjaAPIClient.maxTaskPages + 4
    VikunjaStubProtocol.handler = { request in
      let page = Self.page(of: request)
      let projects = (0..<perPage).map { ["id": page * 1000 + $0 + 1, "title": "P\($0)"] as [String: Any] }
      return (
        200, ["x-pagination-total-pages": "\(pages)"],
        try! JSONSerialization.data(withJSONObject: projects)
      )
    }
    let projects = try await makeClient().fetchProjects()
    XCTAssertEqual(projects.count, perPage * pages)
  }

  func testOneFailingConnectionDoesNotHideTheOthers() async throws {
    VikunjaStubProtocol.handler = { request in
      if request.url?.host == "broken.example.com" {
        return (401, [:], Data(#"{"message":"invalid token"}"#.utf8))
      }
      return (200, [:], Self.tasksPage(1, count: 2))
    }
    let connections = ["healthy.example.com", "broken.example.com", "other.example.com"].map {
      VikunjaConnection(
        record: ExtensionConnectionRecord(
          providerIdentifier: VikunjaCatalogSupport.providerIdentifier, displayName: $0,
          baseURLString: "https://\($0)"),
        accessToken: "token")
    }
    let session = VikunjaStubProtocol.session()
    let results = await VikunjaCatalogSupport.loadPerConnection(connections) { connection in
      try await VikunjaAPIClient(connection: connection, session: session).fetchOpenTasks()
    }

    XCTAssertEqual(results.map(\.connection.displayName), connections.map(\.displayName))
    XCTAssertEqual(try results[0].payload.get().tasks.count, 2)
    XCTAssertThrowsError(try results[1].payload.get()) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .invalidToken)
    }
    XCTAssertEqual(try results[2].payload.get().tasks.count, 2)
  }
}
