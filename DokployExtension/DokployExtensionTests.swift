import Foundation
import TunaKit
import XCTest
@testable import DokployExtension

final class DokployExtensionTests: XCTestCase {
  private static let apiKey = "test-secret-key-123"

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  // MARK: - Declaration

  @MainActor
  func testDeclarationIDsAreStable() throws {
    let declaration = try XCTUnwrap(DokployExtension(bundle: Bundle(for: DokployExtension.self)).declaration)
    try declaration.validate()
    XCTAssertEqual(declaration.catalogs.map(\.id), ["dokploy-apps", "dokploy"])
    XCTAssertEqual(declaration.catalogs.map(\.presentation), [.source, .browseRoot(contents: "dokploy-apps")])
    XCTAssertEqual(declaration.catalogs.map(\.initialGlobalScope), [.none, .none])
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["dokploy-actions"])
    XCTAssertEqual(
      declaration.typeRegistrations.map(\.typeID), [.dokployApplication, .dokployCompose])
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.95")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.21.0")
  }

  @MainActor
  func testActionsTargetOnlyDokployServices() throws {
    let catalog = DokployActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "dokploy-actions", name: "Dokploy Actions"))
    XCTAssertEqual(
      catalog.actions.map(\.id),
      ["deploy", "redeploy", "start", "stop", "open-in-dokploy", "open-domain", "copy-url"])
    for action in catalog.actions {
      XCTAssertEqual(action.supportedSubjectTypes, [.dokployApplication, .dokployCompose], action.id)
    }
  }

  @MainActor
  func testDefaultRankingsReferenceDeclaredActions() throws {
    let declaration = try XCTUnwrap(DokployExtension(bundle: Bundle(for: DokployExtension.self)).declaration)
    let catalog = DokployActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "dokploy-actions", name: "Dokploy Actions"))
    let actionIDs = Set(catalog.actions.map(\.id))
    for ranking in declaration.defaultActionRankings {
      for reference in ranking.actions {
        XCTAssertEqual(reference.catalogIdentifier, "dokploy-actions")
        XCTAssertTrue(actionIDs.contains(reference.actionID), reference.actionID)
      }
    }
  }

  // MARK: - Configuration

  func testConfigurationNormalizesURL() throws {
    let cases = [
      "dokploy.example.com": "https://dokploy.example.com",
      "https://dokploy.example.com/": "https://dokploy.example.com",
      " https://dokploy.example.com/api/ ": "https://dokploy.example.com",
      "http://10.0.0.5:3000": "http://10.0.0.5:3000",
    ]
    for (input, expected) in cases {
      let configuration = try XCTUnwrap(DokployConfiguration(baseURLString: input, apiKey: "k"), input)
      XCTAssertEqual(configuration.baseURL.absoluteString, expected, input)
    }
    XCTAssertNil(DokployConfiguration(baseURLString: "", apiKey: "k"))
    XCTAssertNil(DokployConfiguration(baseURLString: "https://x.com", apiKey: ""))
    XCTAssertNil(DokployConfiguration(baseURLString: "ftp://x.com", apiKey: "k"))
  }

  func testConfigurationDescriptionHidesKey() {
    let configuration = DokployConfiguration(baseURLString: "https://d.example.com", apiKey: Self.apiKey)!
    XCTAssertFalse(String(describing: configuration).contains(Self.apiKey))
    XCTAssertFalse(String(reflecting: configuration).contains(Self.apiKey))
  }

  // MARK: - Decoding

  func testDecodesEnvironmentShape() async throws {
    stub(status: 200, body: DokployFixtures.projectsWithEnvironments)
    let services = try await makeClient().services()

    XCTAssertEqual(services.map(\.itemID), ["application/app_1", "application/app_2", "compose/cmp_1"])
    let frontend = services[0]
    XCTAssertEqual(frontend.name, "frontend")
    XCTAssertEqual(frontend.projectName, "Web")
    XCTAssertEqual(frontend.environmentName, "production")
    XCTAssertEqual(frontend.statusLabel, "Deployed")
    XCTAssertEqual(services[1].statusLabel, "Error")
    XCTAssertEqual(services[2].kind, .compose)
    XCTAssertEqual(services[2].statusLabel, "Deploying")
    XCTAssertEqual(
      frontend.panelURL(baseURL: URL(string: "https://d.example.com")!).absoluteString,
      "https://d.example.com/dashboard/project/proj_1/environment/env_prod/services/application/app_1")
  }

  func testDecodesLegacyShape() async throws {
    stub(status: 200, body: DokployFixtures.legacyProjects)
    let services = try await makeClient().services()

    XCTAssertEqual(services.map(\.itemID), ["application/app_old", "compose/cmp_old"])
    XCTAssertNil(services[0].environmentID)
    XCTAssertNil(services[1].statusLabel)
    XCTAssertEqual(
      services[1].panelURL(baseURL: URL(string: "https://d.example.com")!).absoluteString,
      "https://d.example.com/dashboard/project/proj_old/services/compose/cmp_old")
  }

  func testDecodesDomainsAndPicksFirstEnabled() async throws {
    stub(status: 200, body: DokployFixtures.domains)
    let domains = try await makeClient().domains(for: Self.service(kind: .compose))
    XCTAssertEqual(domains.count, 3)
    XCTAssertEqual(DokployDomain.primaryURL(in: domains)?.absoluteString, "https://app.example.com/docs")
    XCTAssertEqual(domains[2].url?.absoluteString, "http://plain.example.com")
    XCTAssertNil(DokployDomain.primaryURL(in: []))
  }

  func testUnexpectedJSONIsInvalidResponse() async {
    stub(status: 200, body: #"{"projects": []}"#)
    await assertThrows(.invalidResponse) { _ = try await self.makeClient().services() }
  }

  // MARK: - Requests

  func testRequestsUseAPIKeyHeaderAndProcedurePaths() async throws {
    var captured: [URLRequest] = []
    MockURLProtocol.requestHandler = { request in
      captured.append(request)
      return (Self.response(request, status: 200), Data("[]".utf8))
    }
    let client = makeClient()
    _ = try await client.services()
    _ = try await client.domains(for: Self.service(kind: .application))
    try await client.perform(.redeploy, on: Self.service(kind: .compose))

    XCTAssertEqual(captured.map(\.httpMethod), ["GET", "GET", "POST"])
    XCTAssertEqual(
      captured.map { $0.url!.absoluteString },
      [
        "https://d.example.com/api/project.all",
        "https://d.example.com/api/domain.byApplicationId?applicationId=svc_1",
        "https://d.example.com/api/compose.redeploy",
      ])
    for request in captured {
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), Self.apiKey)
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    XCTAssertEqual(captured[2].value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(body(of: captured[2]), ["composeId": "svc_1"])
  }

  func testLifecycleOperationsPostServiceIDAndAcceptEmptyBody() async throws {
    var captured: [URLRequest] = []
    MockURLProtocol.requestHandler = { request in
      captured.append(request)
      return (Self.response(request, status: 200), Data())
    }
    let client = makeClient()
    for operation in DokployOperation.allCases {
      try await client.perform(operation, on: Self.service(kind: .application))
    }
    XCTAssertEqual(
      captured.map(\.url!.lastPathComponent),
      ["application.deploy", "application.redeploy", "application.start", "application.stop"])
    XCTAssertEqual(captured.map { body(of: $0) }, Array(repeating: ["applicationId": "svc_1"], count: 4))
    XCTAssertEqual(captured[0].timeoutInterval, DokployClient.requestTimeout)
    XCTAssertEqual(captured[3].timeoutInterval, DokployClient.lifecycleTimeout)
  }

  // MARK: - Errors

  func testWrongKeyIsUnauthorized() async {
    stub(status: 401, body: DokployFixtures.unauthorized)
    await assertThrows(.unauthorized) { _ = try await self.makeClient().services() }
  }

  func testTRPCErrorsMapStatusAndMessage() async {
    stub(status: 404, body: DokployFixtures.trpcNotFound)
    await assertThrows(.notFound) {
      try await self.makeClient().perform(.deploy, on: Self.service(kind: .application))
    }

    stub(status: 400, body: DokployFixtures.trpcBadRequest)
    await assertThrows(.server(status: 400, message: "Deployment already running")) {
      try await self.makeClient().perform(.deploy, on: Self.service(kind: .application))
    }

    stub(status: 502, body: "<html>Bad Gateway</html>")
    await assertThrows(.server(status: 502, message: nil)) { _ = try await self.makeClient().services() }
  }

  func testTimeoutIsReported() async {
    MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
    await assertThrows(.timedOut) { _ = try await self.makeClient().services() }
  }

  func testUnreachableServerIsReported() async {
    // Nothing listens on port 1; use a real session so the connection is actually refused.
    let configuration = DokployConfiguration(baseURLString: "http://127.0.0.1:1", apiKey: Self.apiKey)!
    let client = DokployClient(configuration: configuration, session: URLSession(configuration: .ephemeral))
    await assertThrows(.unreachable) { _ = try await client.services() }
  }

  func testErrorMessagesNeverContainAPIKey() {
    let errors: [DokployAPIError] = [
      .unauthorized, .forbidden, .notFound, .timedOut, .unreachable, .invalidResponse,
      .server(status: 500, message: "boom"),
    ]
    for error in errors {
      XCTAssertFalse(error.errorDescription!.contains(Self.apiKey))
      XCTAssertFalse(error.title.contains(Self.apiKey))
    }
  }

  // MARK: - Scan and actions

  @MainActor
  func testScanWithoutConnectionsShowsConfigureMessage() async {
    let snapshot = await DokployScanner.scan(connections: [], savedRecordCount: 0) { _ in
      MockClient(result: .success([]))
    }
    XCTAssertTrue(snapshot.services.isEmpty)
    XCTAssertEqual(snapshot.messages.map(\.title), ["Configure Dokploy"])

    let incomplete = await DokployScanner.scan(connections: [], savedRecordCount: 1) { _ in
      MockClient(result: .success([]))
    }
    XCTAssertEqual(incomplete.messages.map(\.title), ["Dokploy connection incomplete"])
  }

  @MainActor
  func testScanKeepsHealthyServerWhenAnotherFails() async {
    let good = Self.connection(id: "a", name: "Prod")
    let bad = Self.connection(id: "b", name: "Lab")
    let snapshot = await DokployScanner.scan(connections: [good, bad], savedRecordCount: 2) {
      connection in
      connection.recordID == "a"
        ? MockClient(result: .success([Self.service(kind: .application)]))
        : MockClient(result: .failure(DokployAPIError.unauthorized))
    }
    XCTAssertEqual(snapshot.services.map(\.id), ["application/svc_1"])
    XCTAssertEqual(snapshot.services.first?.typeID, .dokployApplication)
    XCTAssertEqual(snapshot.services.first?.title, "Prod: web-app")
    XCTAssertEqual(snapshot.services.first?.detail, "Web · production · Application · Deployed")
    XCTAssertEqual(snapshot.messages.map(\.title), ["Lab: Invalid Dokploy API key"])
  }

  @MainActor
  func testScanReportsEmptyServer() async {
    let snapshot = await DokployScanner.scan(
      connections: [Self.connection(id: "a", name: "Prod")], savedRecordCount: 1
    ) { _ in MockClient(result: .success([])) }
    XCTAssertEqual(snapshot.messages.map(\.title), ["No Dokploy services"])
  }

  @MainActor
  func testRunReportsSuccessAndReadableFailure() async {
    let service = Self.service(kind: .application)
    let connection = Self.connection(id: "a", name: "Prod")

    let ok = await DokployActionsCatalog.run(
      .deploy, on: service, connection: connection, client: MockClient(result: .success([])))
    guard case .success = ok else { return XCTFail("expected success") }

    let failed = await DokployActionsCatalog.run(
      .stop, on: service, connection: connection,
      client: MockClient(result: .failure(DokployAPIError.unauthorized)))
    guard case .failure(let message) = failed else { return XCTFail("expected failure") }
    XCTAssertTrue(message?.hasPrefix("Stop web-app failed: The API key was rejected") == true, message ?? "")
  }

  @MainActor
  func testDomainLookupWithoutDomainsFails() async {
    let lookup = await DokployActionsCatalog.primaryDomain(
      of: Self.service(kind: .compose), connection: Self.connection(id: "a", name: "Prod"),
      client: MockClient(result: .success([])))
    XCTAssertEqual(lookup, .failure("web-app has no domain in Dokploy"))
  }

  // MARK: - Helpers

  private func makeClient() -> DokployClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return DokployClient(
      configuration: DokployConfiguration(baseURLString: "https://d.example.com", apiKey: Self.apiKey)!,
      session: URLSession(configuration: configuration))
  }

  private func stub(status: Int, body: String) {
    MockURLProtocol.requestHandler = { request in
      (Self.response(request, status: status), Data(body.utf8))
    }
  }

  private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  private func body(of request: URLRequest) -> [String: String]? {
    guard let stream = request.httpBodyStream ?? request.httpBody.map(InputStream.init(data:)) else {
      return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: String]
  }

  private func assertThrows(
    _ expected: DokployAPIError, file: StaticString = #filePath, line: UInt = #line,
    _ body: @escaping () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as DokployAPIError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("unexpected error \(error)", file: file, line: line)
    }
  }

  private static func service(kind: DokployServiceKind) -> DokployService {
    DokployService(
      kind: kind, id: "svc_1", name: "web-app", status: "done", projectID: "proj_1",
      projectName: "Web", environmentID: "env_1", environmentName: "production")
  }

  private static func connection(id: String, name: String) -> DokployConnection {
    DokployConnection(
      recordID: id, displayName: name,
      configuration: DokployConfiguration(baseURLString: "https://\(id).example.com", apiKey: apiKey)!)
  }
}

private struct MockClient: DokployClientProtocol {
  let result: Result<[DokployService], Error>

  func services() async throws -> [DokployService] { try result.get() }
  func perform(_ operation: DokployOperation, on service: DokployService) async throws {
    _ = try result.get()
  }
  func domains(for service: DokployService) async throws -> [DokployDomain] {
    _ = try result.get()
    return []
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      guard let handler = Self.requestHandler else { throw URLError(.badServerResponse) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
