import Foundation
import XCTest

@testable import TunaVikunja

/// Exercises a real Vikunja server. Skipped unless `VIKUNJA_LIVE_TESTS=1` is set in the test
/// process (`make test-live`, or `TEST_RUNNER_VIKUNJA_LIVE_TESTS=1` with xcodebuild), so the
/// normal suite never touches a server even when credentials are lying around.
///
/// Credentials come from `VIKUNJA_TEST_HOST` + `VIKUNJA_TEST_TOKEN`, or from `~/.netrc`:
///
///     machine tasks.example.com login token password API-TOKEN
///
/// With netrc, `VIKUNJA_TEST_HOST` picks the machine (default: the first entry that mentions
/// "vikunja" or "tasks"). The round-trip test creates one task titled "Tuna extension smoke
/// test" in the Inbox, marks it done, then deletes it.
final class VikunjaLiveAPITests: XCTestCase {
  private struct Credentials {
    let host: String
    let token: String
  }

  private static func credentials() -> Credentials? {
    if let host = ProcessInfo.processInfo.environment["VIKUNJA_TEST_HOST"],
      let token = ProcessInfo.processInfo.environment["VIKUNJA_TEST_TOKEN"]
    {
      return Credentials(host: host, token: token)
    }

    let path = ("~/.netrc" as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let tokens = contents.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var index = 0
    var entries: [Credentials] = []
    while index < tokens.count {
      guard tokens[index] == "machine", index + 1 < tokens.count else {
        index += 1
        continue
      }
      let host = tokens[index + 1]
      var password: String?
      var cursor = index + 2
      while cursor + 1 < tokens.count, tokens[cursor] != "machine" {
        if tokens[cursor] == "password" { password = tokens[cursor + 1] }
        cursor += 2
      }
      if let password { entries.append(Credentials(host: host, token: password)) }
      index = cursor
    }

    let preferredHost = ProcessInfo.processInfo.environment["VIKUNJA_TEST_HOST"]
    return entries.first { entry in
      if let preferredHost { return entry.host == preferredHost }
      let lowered = entry.host.lowercased()
      return lowered.contains("vikunja") || lowered.contains("tasks")
    }
  }

  private func makeClient() throws -> VikunjaAPIClient {
    guard ProcessInfo.processInfo.environment["VIKUNJA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Live API tests are opt-in; set VIKUNJA_LIVE_TESTS=1 (make test-live).")
    }
    guard let credentials = Self.credentials() else {
      throw XCTSkip("No Vikunja credentials in ~/.netrc; skipping live API tests.")
    }
    let server = try VikunjaServerConfiguration(baseURLString: credentials.host)
    return VikunjaAPIClient(server: server, token: credentials.token)
  }

  func testFetchProjectsAndOpenTasks() async throws {
    let client = try makeClient()
    let projects = try await client.fetchProjects()
    XCTAssertFalse(projects.isEmpty, "expected at least one project")
    XCTAssertTrue(projects.allSatisfy { $0.id > 0 && !$0.isArchived })

    let tasks = try await client.fetchOpenTasks().tasks
    XCTAssertTrue(tasks.allSatisfy { !$0.done })

    if let project = projects.first(where: { project in tasks.contains { $0.projectID == project.id } }) {
      let projectTasks = try await client.fetchOpenTasks(projectID: project.id).tasks
      XCTAssertTrue(projectTasks.allSatisfy { $0.projectID == project.id && !$0.done })
    }
  }

  func testSearchReturnsOnlyOpenTasks() async throws {
    let client = try makeClient()
    let results = try await client.searchOpenTasks(query: "a").tasks
    XCTAssertTrue(results.allSatisfy { !$0.done })
  }

  func testCreateCompleteAndDeleteRoundTrip() async throws {
    let client = try makeClient()
    let projects = try await client.fetchProjects()
    let inbox = try XCTUnwrap(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "Inbox"))

    let created = try await client.createTask(
      title: "Tuna extension smoke test", projectID: inbox.id)
    XCTAssertEqual(created.projectID, inbox.id)
    XCTAssertFalse(created.done)

    do {
      let completed = try await client.setTaskDone(id: created.id, done: true)
      XCTAssertTrue(completed.done)
      XCTAssertEqual(completed.title, created.title, "full-task update must preserve the title")
    } catch {
      try await client.deleteTask(id: created.id)
      throw error
    }

    try await client.deleteTask(id: created.id)
    await XCTAssertThrowsErrorAsync(try await client.fetchTask(id: created.id)) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .notFound)
    }
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ handler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {
    handler(error)
  }
}
