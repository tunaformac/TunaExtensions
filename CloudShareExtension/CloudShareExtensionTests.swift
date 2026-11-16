import Foundation
import TunaKit
import XCTest
@testable import CloudShareExtension

final class CloudShareExtensionTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    MockURLProtocol.requests = []
    super.tearDown()
  }

  // MARK: - Signature V4 (AWS's published S3 examples)

  private let exampleSigner = CloudShareSigner(
    accessKeyID: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
  )
  private let exampleDate = Date(timeIntervalSince1970: 1_369_353_600)  // 20130524T000000Z

  func testSignsAWSGetObjectExample() throws {
    var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
    request.httpMethod = "GET"
    request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
    exampleSigner.sign(&request, payloadHash: CloudShareSigner.emptyPayloadHash, date: exampleDate)

    let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(
      authorization.contains(
        "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"))
    XCTAssertTrue(authorization.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
    XCTAssertTrue(
      authorization.hasSuffix(
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
  }

  func testSignsAWSListObjectsExampleWithSortedQuery() throws {
    var request = URLRequest(
      url: URL(string: "https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2")!)
    request.httpMethod = "GET"
    exampleSigner.sign(&request, payloadHash: CloudShareSigner.emptyPayloadHash, date: exampleDate)

    let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(
      authorization.hasSuffix(
        "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"))
  }

  func testEncodesKeysLikeS3() {
    XCTAssertEqual(CloudShareSigner.encodePath("a b/ü+c~.txt"), "a%20b/%C3%BC%2Bc~.txt")
    XCTAssertEqual(CloudShareSigner.encode("a/b"), "a%2Fb")
  }

  // MARK: - URLs

  func testDefaultsToVirtualHostedAWSEndpoint() throws {
    let destination = try makeDestination(["Bucket": "my-files", "Region": "eu-central-1"])
    XCTAssertEqual(
      destination.requestURL(forKey: "a b.png").absoluteString,
      "https://my-files.s3.eu-central-1.amazonaws.com/a%20b.png")
    XCTAssertEqual(
      destination.publicURL(forKey: "a b.png").absoluteString,
      "https://my-files.s3.eu-central-1.amazonaws.com/a%20b.png")
  }

  func testDottedBucketsUsePathStyleAndPublicURLUsesCustomDomain() throws {
    let destination = try makeDestination([
      "Bucket": "s3.example.com", "Region": "eu-west-1", "PublicURL": "s3.example.com/",
    ])
    XCTAssertTrue(destination.usesPathStyle)
    XCTAssertEqual(
      destination.requestURL(forKey: "files/x.png").absoluteString,
      "https://s3.eu-west-1.amazonaws.com/s3.example.com/files/x.png")
    XCTAssertEqual(
      destination.bucketURL.absoluteString, "https://s3.eu-west-1.amazonaws.com/s3.example.com/")
    XCTAssertEqual(
      destination.publicURL(forKey: "files/x.png").absoluteString,
      "https://s3.example.com/files/x.png")
  }

  func testCustomEndpointAndPathStyleSetting() throws {
    let destination = try makeDestination(
      ["Bucket": "media", "PathStyle": "true"], baseURL: "http://localhost:9000")
    XCTAssertEqual(
      destination.requestURL(forKey: "x.txt").absoluteString, "http://localhost:9000/media/x.txt")
  }

  // MARK: - Filenames

  func testDefaultTemplateKeepsNameAndAddsRandomSuffix() throws {
    let destination = try makeDestination(["Bucket": "b"])
    var generator = SeededGenerator()
    let key = CloudShareFilename.key(
      for: "Screen Shot 2026.PNG", destination: destination, generator: &generator)
    XCTAssertTrue(key.hasPrefix("Screen-Shot-2026-"), key)
    XCTAssertTrue(key.hasSuffix(".png"), key)
    XCTAssertEqual(key.count, "Screen-Shot-2026-".count + 6 + ".png".count)
  }

  func testTemplateWithoutPlaceholdersGetsRandomSuffix() {
    var generator = SeededGenerator()
    let name = CloudShareFilename.filename(
      for: "x.txt", template: "shared", date: Date(), generator: &generator)
    XCTAssertTrue(name.hasPrefix("shared-"), name)
    XCTAssertEqual(name.count, "shared-".count + 6 + ".txt".count)
  }

  func testPlainFilenameTemplateKeepsOriginalName() {
    var generator = SeededGenerator()
    XCTAssertEqual(
      CloudShareFilename.filename(
        for: "Résumé final.pdf", template: "%filename%", date: Date(), generator: &generator),
      "Resume-final.pdf")
  }

  func testExtPlaceholderPlacesTheExtensionOnce() {
    var generator = SeededGenerator()
    XCTAssertEqual(
      CloudShareFilename.filename(
        for: "a.png", template: "%filename%.%ext%", date: Date(), generator: &generator),
      "a.png")
    XCTAssertEqual(
      CloudShareFilename.filename(
        for: "a.png", template: "%ext%-%filename%", date: Date(), generator: &generator),
      "png-a")
  }

  func testRandomOnlyTemplateAndPrefixDates() throws {
    let destination = try makeDestination([
      "Bucket": "b", "Prefix": "/up/%year%/%month%/", "FilenameTemplate": "%random-10%",
    ])
    var generator = SeededGenerator()
    let date = Date(timeIntervalSince1970: 1_767_225_600 + 86_400 * 40)  // February 2026
    let key = CloudShareFilename.key(
      for: "notes", destination: destination, date: date, generator: &generator)
    let parts = key.split(separator: "/")
    XCTAssertEqual(parts.prefix(3), ["up", "2026", "02"])
    XCTAssertEqual(parts.last?.count, 10)
    XCTAssertEqual(destination.listingPrefix, "up/")
  }

  func testListingPrefix() throws {
    XCTAssertEqual(try makeDestination(["Bucket": "b", "Prefix": "files"]).listingPrefix, "files/")
    XCTAssertEqual(try makeDestination(["Bucket": "b", "Prefix": "%year%"]).listingPrefix, "")
    XCTAssertEqual(try makeDestination(["Bucket": "b"]).listingPrefix, "")
  }

  // MARK: - Settings

  func testIncompleteDestinationNamesMissingFields() {
    XCTAssertThrowsError(try makeDestination(["Region": ""])) { error in
      XCTAssertEqual(
        error as? CloudShareDestinationError,
        .incomplete(name: "Files", missing: ["a Bucket", "a Region"]))
    }
  }

  func testACLIsOffByDefault() throws {
    XCTAssertFalse(try makeDestination(["Bucket": "b"]).sendsPublicACL)
    XCTAssertTrue(try makeDestination(["Bucket": "b", "PublicACL": "true"]).sendsPublicACL)
  }

  @MainActor
  func testDeclarationIsValidAndDeclaresConnectionFields() throws {
    let ext = try CloudShareExtension(bundle: Bundle(for: CloudShareExtension.self))
    try XCTUnwrap(ext.declaration).validate()
    let connection = try XCTUnwrap(ext.connectionDefinitions.first)
    XCTAssertEqual(connection.kind, .secret)
    XCTAssertEqual(connection.fields.map(\.key), CloudShareSettings.fields.map(\.key))
  }

  @MainActor
  func testActionGrammar() {
    let catalog = CloudShareActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "cloudshare.actions", name: "Cloud Share"))
    let byID = Dictionary(uniqueKeysWithValues: catalog.actions.map { ($0.id, $0) })
    XCTAssertEqual(byID["share"]?.title, "Cloud Share")
    XCTAssertEqual(byID["share"]?.targetRequirement, CatalogActionTargetRequirement.none)
    XCTAssertEqual(byID["share-to"]?.title, "Cloud Share to…")
    XCTAssertEqual(byID["share-to"]?.targetRequirement, .required)
    XCTAssertEqual(byID["share-to"]?.allowedTargetTypes, [.cloudShareDestination])
    // Inline variants return the link; the Shelf copies run in the background.
    XCTAssertEqual(byID["share"]?.executionPolicy, .resultDriven)
    XCTAssertEqual(byID["share-to"]?.executionPolicy, .resultDriven)
    XCTAssertEqual(byID["share-to-shelf"]?.title, "Cloud Share to Shelf")
    XCTAssertEqual(byID["share-to-shelf"]?.targetRequirement, CatalogActionTargetRequirement.none)
    XCTAssertEqual(byID["share-to-via-shelf"]?.title, "Cloud Share to Shelf via…")
    XCTAssertEqual(byID["share-to-via-shelf"]?.targetRequirement, .required)
    XCTAssertEqual(byID["share-to-via-shelf"]?.allowedTargetTypes, [.cloudShareDestination])
    XCTAssertEqual(byID["delete"]?.supportedSubjectTypes, [.cloudShareObject])
    XCTAssertEqual(byID["test"]?.supportedSubjectTypes, [.cloudShareDestination])
  }

  @MainActor
  func testShareProblemsStayVisibleAsMessages() async throws {
    let catalog = CloudShareActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "cloudshare.actions", name: "Cloud Share"))
    let shareTo = try XCTUnwrap(catalog.actions.first { $0.id == "share-to" })
    let subject = CatalogEntity(id: "x", title: "x", path: nil)
    let target = CatalogEntity(id: "y", title: "y", path: nil)
    guard case .results(let items) = await shareTo.callback(subject, target) else {
      return XCTFail("Expected a message result, not a failure that only beeps")
    }
    XCTAssertEqual(items.map(\.title), ["Couldn't Cloud Share"])
    XCTAssertEqual(items.first?.detail, "Choose a Cloud Share destination")
  }

  // MARK: - Listings

  func testFailedListingRetriesAfterCooldown() async throws {
    let destination = try makeDestination(["Bucket": "b"])
    let clock = TestClock()
    let loader = CountingLoader(results: [.failure(CloudShareS3Error.invalidResponse), .success([])])
    let store = CloudShareListingStore(loader: loader.load, now: clock.now)

    XCTAssertLoading(store.state(for: destination, catalogIdentifier: "c"))
    try await waitUntil { if case .failed = store.state(for: destination, catalogIdentifier: "c") { true } else { false } }
    XCTAssertEqual(loader.calls, 1, "Shown again right away without retrying")

    clock.advance(CloudShareListingStore.retryInterval)
    XCTAssertLoading(store.state(for: destination, catalogIdentifier: "c"))
    try await waitUntil { if case .loaded = store.state(for: destination, catalogIdentifier: "c") { true } else { false } }
    XCTAssertEqual(loader.calls, 2)
  }

  func testEditedDestinationAndResetListAgain() async throws {
    let original = try makeDestination(["Bucket": "b"])
    let edited = try makeDestination(["Bucket": "other"])
    let loader = CountingLoader(results: [.success([]), .success([]), .success([])])
    let store = CloudShareListingStore(loader: loader.load)

    _ = store.state(for: original, catalogIdentifier: "c")
    try await waitUntil { if case .loaded = store.state(for: original, catalogIdentifier: "c") { true } else { false } }
    XCTAssertLoading(store.state(for: edited, catalogIdentifier: "c"))
    try await waitUntil { if case .loaded = store.state(for: edited, catalogIdentifier: "c") { true } else { false } }
    store.reset()
    XCTAssertLoading(store.state(for: edited, catalogIdentifier: "c"))
    try await waitUntil { loader.calls == 3 }
    XCTAssertEqual(loader.buckets, ["b", "other", "other"])
  }

  // MARK: - S3 responses

  func testParsesListObjectsV2() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>b</Name><IsTruncated>true</IsTruncated>
        <Contents><Key>a &amp; b.png</Key><LastModified>2026-01-02T03:04:05.000Z</LastModified><Size>42</Size></Contents>
        <Contents><Key>folder/</Key><LastModified>2026-01-01T00:00:00Z</LastModified><Size>0</Size></Contents>
        <NextContinuationToken>next+token</NextContinuationToken>
      </ListBucketResult>
      """
    let page = try CloudShareListParser.parse(Data(xml.utf8))
    XCTAssertEqual(page.objects.map(\.key), ["a & b.png", "folder/"])
    XCTAssertEqual(page.objects.first?.size, 42)
    XCTAssertEqual(page.objects.first?.lastModified, Date(timeIntervalSince1970: 1_767_323_045))
    XCTAssertEqual(page.nextContinuationToken, "next+token")
  }

  func testMapsS3ErrorCodes() {
    let xml = "<Error><Code>AccessControlListNotSupported</Code><Message>x</Message></Error>"
    let response = HTTPURLResponse(
      url: URL(string: "https://x")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
    XCTAssertThrowsError(try CloudShareS3Client.validate(data: Data(xml.utf8), response: response)) {
      XCTAssertEqual(
        $0 as? CloudShareS3Error,
        .service(status: 400, code: "AccessControlListNotSupported", message: "x"))
      XCTAssertTrue($0.localizedDescription.contains("ACLs disabled"))
    }
  }

  func testUploadSendsSignedPutWithoutACLByDefault() async throws {
    let destination = try makeDestination(["Bucket": "my-files", "Region": "eu-central-1"])
    MockURLProtocol.requestHandler = { _ in (200, Data()) }
    let client = CloudShareS3Client(destination: destination, session: MockURLProtocol.session())

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
    try Data("hello".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    try await client.putObject(fileURL: file, key: "x.txt", contentType: "text/plain")

    let request = try XCTUnwrap(MockURLProtocol.requests.first)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(
      request.url?.absoluteString, "https://my-files.s3.eu-central-1.amazonaws.com/x.txt")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    XCTAssertNil(request.value(forHTTPHeaderField: "x-amz-acl"))
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "Authorization")?.contains(
        "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date") == true)
  }

  func testListRecentObjectsFollowsPagesAndSortsNewestFirst() async throws {
    let destination = try makeDestination(["Bucket": "b", "Prefix": "files"])
    MockURLProtocol.requestHandler = { request in
      let query = request.url?.query ?? ""
      if query.contains("continuation-token") {
        return (200, Data(Self.listXML(["files/new.png": "2026-03-01T00:00:00Z"]).utf8))
      }
      return (
        200,
        Data(
          Self.listXML(["files/old.png": "2026-01-01T00:00:00Z"], nextToken: "t2").utf8)
      )
    }
    let client = CloudShareS3Client(destination: destination, session: MockURLProtocol.session())
    let result = try await client.listRecentObjects()
    XCTAssertEqual(result.objects.map(\.key), ["files/new.png", "files/old.png"])
    XCTAssertFalse(result.truncated)
    XCTAssertEqual(
      MockURLProtocol.requests.first?.url?.query, "list-type=2&prefix=files%2F")
  }

  // MARK: - Helpers

  private func makeDestination(
    _ fields: [String: String], baseURL: String = ""
  ) throws -> CloudShareDestination {
    var record = ExtensionConnectionRecord(
      id: "files", providerIdentifier: "s3", displayName: "Files", baseURLString: baseURL)
    record.fieldValues = ["AccessKeyID": "AKID"].merging(fields) { $1 }
    return try CloudShareSettings.destination(from: record) { "secret" }
  }

  private static func listXML(_ objects: [String: String], nextToken: String? = nil) -> String {
    let contents = objects.map {
      "<Contents><Key>\($0.key)</Key><LastModified>\($0.value)</LastModified><Size>1</Size></Contents>"
    }.joined()
    let token = nextToken.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
    return "<ListBucketResult>\(contents)\(token)</ListBucketResult>"
  }
}

private func XCTAssertLoading(
  _ state: CloudShareListingStore.State, file: StaticString = #filePath, line: UInt = #line
) {
  guard case .loading = state else {
    return XCTFail("Expected loading, got \(state)", file: file, line: line)
  }
}

private func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  XCTFail("Timed out")
}

private final class TestClock: @unchecked Sendable {
  private let date = LockedValue(Date(timeIntervalSince1970: 0))
  var now: @Sendable () -> Date { { [date] in date.value } }
  func advance(_ interval: TimeInterval) { date.withValue { $0 += interval } }
}

private final class CountingLoader: @unchecked Sendable {
  private let remaining: LockedValue<[Result<[CloudShareObject], Error>]>
  private let seen = LockedValue<[String]>([])

  init(results: [Result<[CloudShareObject], Error>]) {
    remaining = LockedValue(results)
  }

  var calls: Int { seen.value.count }
  var buckets: [String] { seen.value }

  var load: CloudShareListingStore.Loader {
    { [remaining, seen] destination in
      seen.withValue { $0.append(destination.bucket) }
      let result = remaining.withValue { $0.removeFirst() }
      return (try result.get(), false)
    }
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64 = 0x1234_5678

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Int, Data))?
  nonisolated(unsafe) static var requests: [URLRequest] = []

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requests.append(request)
    let (status, data) = Self.requestHandler?(request) ?? (500, Data())
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
