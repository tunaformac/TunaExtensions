import CryptoKit
import Foundation
import TunaKit
import XCTest
@testable import MyMindExtension

final class MyMindExtensionTests: XCTestCase {
  private let credentials = MyMindCredentials(
    keyID: "test-key",
    privateKey: Data("0123456789abcdef".utf8).base64EncodedString(),
    accessLevel: .fullAccess
  )

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  func testJWTBindsUppercaseMethodAndPath() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let token = try MyMindJWTSigner(credentials: credentials)
      .token(method: "get", path: "/objects", now: now)
    let parts = token.split(separator: ".")
    XCTAssertEqual(parts.count, 3)

    let header = try XCTUnwrap(jsonPart(parts[0]))
    let claims = try XCTUnwrap(jsonPart(parts[1]))
    XCTAssertEqual(header["alg"] as? String, "HS256")
    XCTAssertEqual(header["kid"] as? String, "test-key")
    XCTAssertEqual(claims["method"] as? String, "GET")
    XCTAssertEqual(claims["path"] as? String, "/objects")
    XCTAssertEqual(claims["iat"] as? Int, 1_700_000_000)
    XCTAssertEqual(claims["exp"] as? Int, 1_700_000_300)

    let unsigned = "\(parts[0]).\(parts[1])"
    let expected = HMAC<SHA256>.authenticationCode(
      for: Data(unsigned.utf8),
      using: SymmetricKey(data: Data("0123456789abcdef".utf8))
    )
    XCTAssertEqual(String(parts[2]), MyMindJWTSigner.base64URL(Data(expected)))
    XCTAssertFalse(token.contains("="))
  }

  func testRequestSignsPathWithoutQueryAndIdentifiesTuna() throws {
    let request = try MyMindAPIClient(credentials: credentials).makeRequest(
      path: "/objects",
      queryItems: [URLQueryItem(name: "q", value: "design tools")]
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "mymind-for-Tuna/0.1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
    let token = authorization.replacingOccurrences(of: "Bearer ", with: "")
    let claims = try XCTUnwrap(jsonPart(token.split(separator: ".")[1]))
    XCTAssertEqual(claims["path"] as? String, "/objects")
    XCTAssertEqual(claims["method"] as? String, "GET")
    XCTAssertTrue(request.url?.absoluteString.contains("q=design%20tools") == true)
  }

  func testDecodesRepresentativeObjects() async throws {
    let client = mockClient(status: 200, body: Data(Self.objectListJSON.utf8))
    let objects = try await client.listObjects(query: "plain text", limit: 12)
    let object = try XCTUnwrap(objects.first)
    XCTAssertEqual(object.id, "a1B2c3D4e5F6g7H8i9J0k1")
    XCTAssertEqual(object.kind, .article)
    XCTAssertEqual(object.content?.body, "# Plain text")
    XCTAssertEqual(object.sourceURL?.absoluteString, "https://example.com/plain-text")
  }

  func testDecodesObjectWithoutTitle() async throws {
    let json = ##"[{"id":"untitled","content":{"type":"text/markdown","body":"First line\nSecond line"},"tags":[]}]"##
    let objects = try await mockClient(status: 200, body: Data(json.utf8)).listObjects()

    XCTAssertEqual(objects.first?.displayTitle, "First line")
  }

  func testImageObjectPrefersBlobOverSourceURL() async throws {
    let json = ##"[{"id":"image","title":"Image","blob":{"type":"image/png","name":"image.png"},"mainEntity":{"@type":"ImageObject"},"source":{"url":"https://example.com/image"},"tags":[]}]"##
    let objects = try await mockClient(status: 200, body: Data(json.utf8)).listObjects()
    let object = try XCTUnwrap(objects.first)

    XCTAssertEqual(object.kind, .image)
    XCTAssertNotNil(object.blob)
    XCTAssertEqual(object.sourceURL?.absoluteString, "https://example.com/image")
  }

  func testDecodesProblemAndRateLimitReset() async {
    let problem = #"{"type":"RateLimited","status":429,"detail":"Quota exhausted."}"#
    let client = mockClient(
      status: 429,
      body: Data(problem.utf8),
      headers: ["RateLimit": "\"burst\";r=0;t=15, \"sustained\";r=0;t=3600"]
    )
    do {
      _ = try await client.listSpaces()
      XCTFail("Expected rate limit error")
    } catch MyMindAPIError.rateLimited(let reset) {
      XCTAssertEqual(reset, 3_600)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testShortRateLimitResetIncludesSeconds() {
    XCTAssertTrue(MyMindAPIError.rateLimited(resetAfter: 15).localizedDescription.contains("15 seconds"))
  }

  func testCreateURLIncludesOptionalSpace() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
      let body = try Self.bodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["url"] as? String, "https://example.com/article")
      let spaces = try XCTUnwrap(json["spaces"] as? [[String: String]])
      XCTAssertEqual(spaces.first?["id"], "space-1")
      return Self.response(for: request, status: 201, body: Data(Self.objectJSON.utf8))
    }
    let object = try await mockClient().createObject(
      .url(URL(string: "https://example.com/article")!),
      spaceID: "space-1"
    )
    XCTAssertEqual(object.id, "a1B2c3D4e5F6g7H8i9J0k1")
  }

  func testMultipartUploadContainsMetadataFilenameAndBytes() async throws {
    MockURLProtocol.requestHandler = { request in
      let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
      XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
      let body = try Self.bodyData(from: request)
      let text = String(decoding: body, as: UTF8.self)
      XCTAssertTrue(text.contains("name=\"metadata\""))
      XCTAssertTrue(text.contains(#"{"spaces":[{"id":"space-1"}]}"#))
      XCTAssertTrue(text.contains("name=\"blob\"; filename=\"note.txt\""))
      XCTAssertTrue(text.contains("Content-Type: text/plain"))
      XCTAssertTrue(text.contains("fixture bytes"))
      return Self.response(for: request, status: 201, body: Data(Self.objectJSON.utf8))
    }
    _ = try await mockClient().createObject(
      .upload(MyMindUpload(
        body: .data(Data("fixture bytes".utf8)),
        filename: "note.txt",
        contentType: "text/plain"
      )),
      spaceID: "space-1"
    )
  }

  func testReadOnlyCredentialsRejectWritesBeforeRequest() async {
    let client = MyMindAPIClient(credentials: MyMindCredentials(
      keyID: "test-key",
      privateKey: credentials.privateKey,
      accessLevel: .readOnly
    ))
    do {
      _ = try await client.createObject(.content("Nope"), spaceID: nil)
      XCTFail("Expected read-only error")
    } catch MyMindAPIError.readOnlyKey {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  @MainActor func testSupportedUploadFormats() throws {
    XCTAssertEqual(
      MyMindActionsCatalog.supportedContentType(for: URL(fileURLWithPath: "/tmp/card.pdf")),
      "application/pdf"
    )
    XCTAssertNil(
      MyMindActionsCatalog.supportedContentType(for: URL(fileURLWithPath: "/tmp/archive.zip"))
    )
    XCTAssertEqual(
      MyMindActionsCatalog.supportedContentType(for: URL(fileURLWithPath: "/tmp/photo.heic")),
      "image/heif"
    )
  }

  @MainActor func testSaveIsAnAdditiveEntityAction() throws {
    let catalog = MyMindActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.mymind.actions", name: "Actions")
    )
    let save = try XCTUnwrap(catalog.actions.first { $0.id == "save" })

    XCTAssertEqual(save.supportedSubjectTypes, [.entity])
    XCTAssertEqual(
      save.targetSearchScope,
      .catalogs(["mymind.spaces"], preparation: .refresh)
    )
  }

  @MainActor func testURLItemCreatesURLCapture() throws {
    let expected = try XCTUnwrap(URL(string: "https://example.com/article"))
    let item = URLItem(urlString: expected.absoluteString)
    let capture = try XCTUnwrap(MyMindActionsCatalog.capture(from: item))

    guard case .url(let actual) = capture else {
      return XCTFail("Expected URL capture")
    }
    XCTAssertEqual(actual, expected)
  }

  @MainActor func testCatalogsDefaultToNewestFirst() {
    let definition = CatalogDefinition(
      identifier: "test.mymind",
      name: "mymind",
      enabledByDefault: true,
      settings: []
    )

    XCTAssertEqual(MyMindCatalog(definition: definition).defaultSortOptionID, "capturedAt.desc")
    XCTAssertEqual(MyMindSpacesCatalog(definition: definition).defaultSortOptionID, "capturedAt.desc")
  }

  private func mockClient(
    status: Int = 200,
    body: Data? = nil,
    headers: [String: String] = [:]
  ) -> MyMindAPIClient {
    if MockURLProtocol.requestHandler == nil {
      MockURLProtocol.requestHandler = { request in
        Self.response(
          for: request,
          status: status,
          body: body ?? Data(Self.objectJSON.utf8),
          headers: headers
        )
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return MyMindAPIClient(
      credentials: credentials,
      session: URLSession(configuration: configuration),
      baseURL: URL(string: "https://api.example.test")!
    )
  }

  private func jsonPart(_ part: Substring) -> [String: Any]? {
    var value = String(part).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func response(
    for request: URLRequest,
    status: Int,
    body: Data,
    headers: [String: String] = [:]
  ) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
      )!,
      body
    )
  }

  private static func bodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw try XCTUnwrap(stream.streamError) }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private static let objectJSON = #"{"id":"a1B2c3D4e5F6g7H8i9J0k1","title":"Example Article","tags":[],"source":{"url":"https://example.com/article"},"created":"2024-04-08T09:00:00Z","modified":"2024-04-08T09:00:00Z","bumped":"2024-04-08T09:00:00Z"}"#
  private static let objectListJSON = ##"[{"id":"a1B2c3D4e5F6g7H8i9J0k1","title":"The Art of Plain Text","content":{"type":"text/markdown","body":"# Plain text"},"mainEntity":{"@type":["Article","WebPage"]},"tags":[{"name":"writing"}],"source":{"url":"https://example.com/plain-text"},"created":"2024-03-01T12:00:00.123Z","modified":"2024-03-01T12:00:00Z","bumped":"2024-03-01T12:00:00Z"}]"##
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
