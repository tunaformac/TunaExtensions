import AppKit
import Foundation
import TunaKit
import XCTest

@testable import TunaGiphy

final class GiphyExtensionTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  @MainActor
  func testDeclarationExposesOneLazyLiveSearchCatalog() throws {
    let instance = try GiphyExtension(bundle: Bundle(for: GiphyExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.catalogs.map(\.id), ["giphy"])
    XCTAssertEqual(declaration.catalogs.first?.presentation, .liveSearch)
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["giphy.actions"])
    XCTAssertTrue(declaration.appBrowseEnrichments.isEmpty)
    XCTAssertEqual(declaration.settings.map(\.key), ["APIKey", "Rating"])
    XCTAssertEqual(declaration.settings.first?.type, .secret)

    let catalog = GiphyCatalog(
      definition: CatalogDefinition(
        identifier: "giphy",
        name: "GIPHY",
        enabledByDefault: true,
        settings: []
      )
    )
    XCTAssertFalse(catalog.scansOnStartup)
    XCTAssertEqual(catalog.resultsViewStyle, .grid)
    XCTAssertEqual(catalog.objects.count, 1)
    XCTAssertTrue(try XCTUnwrap(catalog.objects.first) is ScopedCatalogSearchPagingProviding)

    let actionCatalog = GiphyActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "giphy.actions", name: "GIPHY Actions")
    )
    XCTAssertEqual(actionCatalog.actions.map(\.id), ["copy-url", "resolve"])
    XCTAssertTrue(actionCatalog.actions.allSatisfy { $0.supportedSubjectTypes == [.giphyGIF] })

    let ranking = try XCTUnwrap(declaration.defaultActionRankings.first)
    XCTAssertEqual(ranking.typeID, .giphyGIF)
    XCTAssertEqual(ranking.actions.map(\.actionID), ["copy-url", "resolve"])
  }

  func testSearchRequestPreservesQueryAndPaginates() async throws {
    MockURLProtocol.requestHandler = { request in
      let components = try XCTUnwrap(
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      )
      let values = Dictionary(
        uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? [])
      XCTAssertEqual(request.url?.path, "/v1/gifs/search")
      XCTAssertEqual(values["q"] ?? nil, "happy birthday 🎂")
      XCTAssertEqual(values["offset"] ?? nil, "25")
      XCTAssertEqual(values["limit"] ?? nil, "25")
      XCTAssertEqual(values["api_key"] ?? nil, "test-key")
      XCTAssertEqual(values["customer_id"] ?? nil, "test-customer")
      XCTAssertEqual(values["bundle"] ?? nil, "messaging_non_clips")
      return Self.response(request, status: 200, body: Self.responseJSON)
    }

    let result = try await mockClient().page(query: "happy birthday 🎂", page: 2)

    XCTAssertEqual(result.gifs.map(\.id), ["abc123"])
    XCTAssertFalse(result.hasMore)
  }

  func testTrendingUsesTrendingEndpointWithoutQuery() async throws {
    MockURLProtocol.requestHandler = { request in
      let components = try XCTUnwrap(
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      )
      XCTAssertEqual(request.url?.path, "/v1/gifs/trending")
      XCTAssertNil(components.queryItems?.first { $0.name == "q" })
      return Self.response(request, status: 200, body: Self.responseJSON)
    }

    _ = try await mockClient().page(query: nil, page: 1)
  }

  func testAnalyticsURLAddsAnonymousIdentityAndTimestamp() async throws {
    let reporter = GiphyAnalyticsReporter(
      session: mockSession(),
      customerID: { "test-customer" }
    )
    let generatedURL = await reporter.trackingURL(
        from: URL(
          string:
            "https://giphy-analytics.giphy.com/v2/pingback_simple?analytics_response_payload=e%3DZ2lm%2BaWQ%2F&action_type=SEEN"
      )!,
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let url = try XCTUnwrap(generatedURL)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = Dictionary(
      uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? [])

    XCTAssertEqual(values["analytics_response_payload"] ?? nil, "e=Z2lm+aWQ/")
    XCTAssertEqual(values["action_type"] ?? nil, "SEEN")
    XCTAssertEqual(values["customer_id"] ?? nil, "test-customer")
    XCTAssertEqual(values["ts"] ?? nil, "1700000000000")
    XCTAssertTrue(url.absoluteString.contains("analytics_response_payload=e%3DZ2lm%2BaWQ%2F"))
  }

  func testAnalyticsDecodingAndRequestUseProviderURL() async throws {
    let gif = try JSONDecoder().decode(GiphyGIF.self, from: Data(Self.analyticsGIFJSON.utf8))
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.host, "giphy-analytics.giphy.com")
      XCTAssertTrue(request.url?.absoluteString.contains("action_type=CLICK") == true)
      XCTAssertTrue(request.url?.absoluteString.contains("customer_id=test-customer") == true)
      return Self.response(request, status: 200, body: "{}")
    }
    let reporter = GiphyAnalyticsReporter(
      session: mockSession(),
      customerID: { "test-customer" }
    )

    await reporter.report(.activated, for: gif)
  }

  func testAnalyticsRejectsNonGiphyHost() async {
    let reporter = GiphyAnalyticsReporter(customerID: { "test-customer" })
    let url = await reporter.trackingURL(
      from: URL(string: "https://example.com/ping?payload=secret")!)

    XCTAssertNil(url)
  }

  func testInvalidAPIKeyResponseHasSpecificError() async throws {
    MockURLProtocol.requestHandler = { request in
      Self.response(
        request,
        status: 401,
        body: #"{"meta":{"status":401,"msg":"Unauthorized"}}"#)
    }

    do {
      _ = try await mockClient().page(query: nil, page: 1)
      XCTFail("Expected invalid API key error")
    } catch GiphyAPIError.invalidAPIKey {
    } catch {
      XCTFail("Expected invalid API key error, got \(error)")
    }
  }

  func testGIFItemProvidesAnimatedHTMLAndURLFallback() throws {
    let gif = try JSONDecoder().decode(
      GiphyGIF.self,
      from: Data(Self.gifJSON.utf8)
    )
    let item = GiphyGIFItem(gif: gif)
    let representation = try XCTUnwrap(item.pasteboardDataRepresentation)

    XCTAssertEqual(item.id, "giphy.gif.abc123")
    XCTAssertEqual(item.typeID, .giphyGIF)
    XCTAssertEqual(item.copyRepresentation, "https://media.giphy.com/original.gif")
    XCTAssertTrue(item is CatalogQuickLookProviding)
    XCTAssertEqual(representation.pasteboardType, .html)
    XCTAssertEqual(
      String(decoding: representation.data, as: UTF8.self),
      #"<img src="https://media.giphy.com/original.gif" alt="A happy &amp; dancing cat">"#
    )
  }

  func testResolverDownloadsGIFToTemporaryLocalFile() async throws {
    let gif = try JSONDecoder().decode(GiphyGIF.self, from: Data(Self.gifJSON.utf8))
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = Data("GIF89a-test-data".utf8)

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url, gif.originalURL)
      return Self.response(
        request,
        status: 200,
        body: data,
        contentType: "image/gif"
      )
    }

    let file = try await GiphyResolver(
      session: mockSession(),
      directory: directory
    ).resolve(gif)

    XCTAssertEqual(file.kind, .file)
    XCTAssertEqual(file.url.lastPathComponent, "giphy-abc123.gif")
    XCTAssertEqual(try Data(contentsOf: file.url), data)
  }

  private func mockClient() -> GiphyAPIClient {
    GiphyAPIClient(
      session: mockSession(),
      baseURL: URL(string: "https://api.example.test/v1/gifs")!,
      apiKey: { "test-key" },
      customerID: { "test-customer" }
    )
  }

  private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func response(
    _ request: URLRequest,
    status: Int,
    body: String
  ) -> (HTTPURLResponse, Data) {
    response(request, status: status, body: Data(body.utf8))
  }

  private static func response(
    _ request: URLRequest,
    status: Int,
    body: Data,
    contentType: String = "application/json"
  ) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": contentType]
      )!,
      body
    )
  }

  private static let gifJSON = #"{"id":"abc123","title":"Happy Cat GIF","alt_text":"A happy & dancing cat","username":"cats","url":"https://giphy.com/gifs/abc123","images":{"fixed_width":{"url":"https://media.giphy.com/preview.gif"},"original":{"url":"https://media.giphy.com/original.gif"}}}"#
  private static let analyticsGIFJSON = #"{"id":"abc123","title":"Happy Cat GIF","alt_text":"A happy cat","username":"cats","url":"https://giphy.com/gifs/abc123","images":{"fixed_width":{"url":"https://media.giphy.com/preview.gif"},"original":{"url":"https://media.giphy.com/original.gif"}},"analytics":{"onload":{"url":"https://giphy-analytics.giphy.com/v2/pingback_simple?action_type=SEEN"},"onclick":{"url":"https://giphy-analytics.giphy.com/v2/pingback_simple?action_type=CLICK"},"onsent":{"url":"https://giphy-analytics.giphy.com/v2/pingback_simple?action_type=SENT"}}}"#
  private static let responseJSON = #"{"data":[{"id":"abc123","title":"Happy Cat GIF","alt_text":"A happy & dancing cat","username":"cats","url":"https://giphy.com/gifs/abc123","images":{"fixed_width":{"url":"https://media.giphy.com/preview.gif"},"original":{"url":"https://media.giphy.com/original.gif"}}}],"pagination":{"total_count":1,"count":1,"offset":25},"meta":{"status":200,"msg":"OK"}}"#
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try XCTUnwrap(Self.requestHandler)
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
