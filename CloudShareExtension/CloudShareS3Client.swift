import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 requests.
struct CloudShareSigner: Sendable {
  static let unsignedPayload = "UNSIGNED-PAYLOAD"
  static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  let accessKeyID: String
  let secretAccessKey: String
  let region: String
  var service = "s3"

  /// Adds `Host`, `x-amz-date`, `x-amz-content-sha256`, and `Authorization` to `request`.
  /// Every header already on the request is signed.
  func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
    let amzDate = Self.timestamp(date, format: "yyyyMMdd'T'HHmmss'Z'")
    let scopeDate = String(amzDate.prefix(8))
    guard let url = request.url, let host = url.host else { return }

    let hostHeader = url.port.map { "\(host):\($0)" } ?? host
    request.setValue(hostHeader, forHTTPHeaderField: "Host")
    request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

    var headers: [(String, String)] = []
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      headers.append((name.lowercased(), Self.trimmedHeaderValue(value)))
    }
    headers.sort { $0.0 < $1.0 }
    let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
    let signedHeaders = headers.map(\.0).joined(separator: ";")

    let canonicalRequest = [
      request.httpMethod ?? "GET",
      Self.canonicalURI(url),
      Self.canonicalQuery(url),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")

    let scope = "\(scopeDate)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      scope,
      Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
    ].joined(separator: "\n")

    var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
    for part in [scopeDate, region, service, "aws4_request"] {
      key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    let signature = Self.hex(
      HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

    request.setValue(
      "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// RFC 3986 encoding as S3 expects: everything except unreserved characters.
  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  /// Encodes each path segment, keeping `/` separators.
  static func encodePath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
      .map { encode(String($0)) }
      .joined(separator: "/")
  }

  static func canonicalURI(_ url: URL) -> String {
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    return path.isEmpty ? "/" : path
  }

  static func canonicalQuery(_ url: URL) -> String {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
      return ""
    }
    let pairs: [(name: String, value: String)] = items.map {
      (encode($0.name), encode($0.value ?? ""))
    }
    let sorted = pairs.sorted { lhs, rhs in
      lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
    }
    return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
  }

  private static func trimmedHeaderValue(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespaces)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }

  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp(_ date: Date, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}

struct CloudShareObject: Sendable, Hashable {
  let key: String
  let size: Int64
  let lastModified: Date
}

struct CloudShareListPage: Sendable {
  let objects: [CloudShareObject]
  let nextContinuationToken: String?
}

enum CloudShareS3Error: LocalizedError, Equatable {
  case service(status: Int, code: String?, message: String?)
  case invalidResponse
  case publicURLUnreachable(URL, status: Int?)
  case publicURLMismatch(URL)

  var errorDescription: String? {
    switch self {
    case .service(let status, let code, let message):
      switch code {
      case "AccessDenied":
        return "Access denied. Check the key's permissions for this bucket."
      case "AccessControlListNotSupported":
        return "This bucket has ACLs disabled. Turn off \u{201C}Upload with public-read ACL\u{201D}."
      case "InvalidAccessKeyId":
        return "The Access Key ID is not valid."
      case "SignatureDoesNotMatch":
        return "The secret access key does not match the Access Key ID."
      case "NoSuchBucket":
        return "The bucket does not exist."
      case "PermanentRedirect", "AuthorizationHeaderMalformed":
        return "The bucket is in a different region. Check the Region setting."
      default:
        let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
        return detail.isEmpty ? "S3 returned HTTP \(status)." : "S3 error \(status): \(detail)"
      }
    case .invalidResponse:
      return "S3 returned an unreadable response."
    case .publicURLUnreachable(let url, let status):
      let reason = status.map { "HTTP \($0)" } ?? "no response"
      return "Uploaded, but \(url.absoluteString) returned \(reason). Make the bucket public or check the Public URL."
    case .publicURLMismatch(let url):
      return "\(url.absoluteString) served different content than was uploaded. Check the Public URL."
    }
  }
}

struct CloudShareS3Client: Sendable {
  let destination: CloudShareDestination
  let session: URLSession

  init(destination: CloudShareDestination, session: URLSession = .shared) {
    self.destination = destination
    self.session = session
  }

  private func signer() throws -> CloudShareSigner {
    guard let secret = destination.secretProvider(), !secret.isEmpty else {
      throw CloudShareDestinationError.missingSecret(name: destination.name)
    }
    return CloudShareSigner(
      accessKeyID: destination.accessKeyID,
      secretAccessKey: secret,
      region: destination.region
    )
  }

  func putObject(fileURL: URL, key: String, contentType: String) async throws {
    var request = URLRequest(url: destination.requestURL(forKey: key))
    request.httpMethod = "PUT"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    if destination.sendsPublicACL {
      request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
    }
    try signer().sign(&request, payloadHash: CloudShareSigner.unsignedPayload)
    let (data, response) = try await session.upload(for: request, fromFile: fileURL)
    try Self.validate(data: data, response: response)
  }

  func listObjects(continuationToken: String? = nil) async throws -> CloudShareListPage {
    var components = URLComponents(url: destination.bucketURL, resolvingAgainstBaseURL: false)!
    var items = [URLQueryItem(name: "list-type", value: "2")]
    if !destination.listingPrefix.isEmpty {
      items.append(URLQueryItem(name: "prefix", value: destination.listingPrefix))
    }
    if let continuationToken {
      items.append(URLQueryItem(name: "continuation-token", value: continuationToken))
    }
    components.percentEncodedQuery = items
      .map { "\(CloudShareSigner.encode($0.name))=\(CloudShareSigner.encode($0.value ?? ""))" }
      .joined(separator: "&")

    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    try signer().sign(&request, payloadHash: CloudShareSigner.emptyPayloadHash)
    let (data, response) = try await session.data(for: request)
    try Self.validate(data: data, response: response)
    return try CloudShareListParser.parse(data)
  }

  /// Lists newest first. S3 lists keys alphabetically, so recency needs every page; `limit`
  /// caps how many keys are fetched for very large buckets.
  func listRecentObjects(limit: Int = 5_000) async throws -> (objects: [CloudShareObject], truncated: Bool) {
    var objects: [CloudShareObject] = []
    var token: String?
    repeat {
      let page = try await listObjects(continuationToken: token)
      objects += page.objects
      token = page.nextContinuationToken
    } while token != nil && objects.count < limit
    let visible = objects.filter { !$0.key.hasSuffix("/") }
    return (visible.sorted { $0.lastModified > $1.lastModified }, token != nil)
  }

  func deleteObject(key: String) async throws {
    var request = URLRequest(url: destination.requestURL(forKey: key))
    request.httpMethod = "DELETE"
    try signer().sign(&request, payloadHash: CloudShareSigner.emptyPayloadHash)
    let (data, response) = try await session.data(for: request)
    try Self.validate(data: data, response: response)
  }

  /// Fetches a shared link without credentials, as a recipient would.
  func fetchPublic(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let response: URLResponse
    let data: Data
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw CloudShareS3Error.publicURLUnreachable(url, status: nil)
    }
    let status = (response as? HTTPURLResponse)?.statusCode
    guard let status, (200..<300).contains(status) else {
      throw CloudShareS3Error.publicURLUnreachable(url, status: status)
    }
    return data
  }

  static func validate(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw CloudShareS3Error.invalidResponse
    }
    guard !(200..<300).contains(http.statusCode) else { return }
    let error = CloudShareErrorParser.parse(data)
    throw CloudShareS3Error.service(
      status: http.statusCode, code: error.code, message: error.message)
  }
}

/// Parses ListObjectsV2 XML.
final class CloudShareListParser: NSObject, XMLParserDelegate {
  private var objects: [CloudShareObject] = []
  private var nextToken: String?
  private var text = ""
  private var key: String?
  private var size: Int64 = 0
  private var lastModified: Date?
  private var inContents = false

  static func parse(_ data: Data) throws -> CloudShareListPage {
    let delegate = CloudShareListParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw CloudShareS3Error.invalidResponse }
    return CloudShareListPage(objects: delegate.objects, nextContinuationToken: delegate.nextToken)
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    text = ""
    if elementName == "Contents" {
      inContents = true
      key = nil
      size = 0
      lastModified = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "Key" where inContents: key = text
    case "Size" where inContents: size = Int64(text) ?? 0
    case "LastModified" where inContents: lastModified = Self.parseDate(text)
    case "NextContinuationToken": nextToken = text.isEmpty ? nil : text
    case "Contents":
      inContents = false
      if let key {
        objects.append(
          CloudShareObject(key: key, size: size, lastModified: lastModified ?? .distantPast))
      }
    default: break
    }
  }

  private static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

/// Reads `<Error><Code>…</Code><Message>…</Message></Error>` bodies.
final class CloudShareErrorParser: NSObject, XMLParserDelegate {
  private var text = ""
  private(set) var code: String?
  private(set) var message: String?

  static func parse(_ data: Data) -> (code: String?, message: String?) {
    let delegate = CloudShareErrorParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return (delegate.code, delegate.message)
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "Code" { code = text }
    if elementName == "Message" { message = text }
  }
}
