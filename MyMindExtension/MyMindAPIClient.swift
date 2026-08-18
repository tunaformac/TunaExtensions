import CryptoKit
import Foundation

enum MyMindAccessLevel: String, Sendable {
  case readOnly = "read-only"
  case fullAccess = "full-access"

  var canWrite: Bool { self == .fullAccess }
}

struct MyMindCredentials: Sendable {
  let keyID: String
  let privateKey: String
  let accessLevel: MyMindAccessLevel
}

struct MyMindSpace: Codable, Sendable {
  let id: String
  let name: String
  let color: String?
  let created: Date?
}

struct MyMindObject: Codable, Sendable {
  struct Reference: Codable, Sendable {
    let id: String
  }

  struct Source: Codable, Sendable {
    let url: URL
  }

  struct Blob: Codable, Sendable {
    let path: String?
    let type: String
    let name: String?
    let url: URL?
    let width: Int?
    let height: Int?
  }

  struct Content: Codable, Sendable {
    let type: String
    let body: String?

    init(type: String, body: String) {
      self.type = type
      self.body = body
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decode(String.self, forKey: .type)
      body = try? container.decode(String.self, forKey: .body)
    }
  }

  struct Entity: Codable, Sendable {
    let types: [String]

    enum CodingKeys: String, CodingKey {
      case types = "@type"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let type = try? container.decode(String.self, forKey: .types) {
        types = [type]
      } else {
        types = try container.decode([String].self, forKey: .types)
      }
    }
  }

  struct Tag: Codable, Sendable {
    let name: String
  }

  let id: String
  let title: String?
  let blob: Blob?
  let content: Content?
  let mainEntity: Entity?
  let summary: String?
  let screenshot: Blob?
  let spaces: [Reference]?
  let tags: [Tag]
  let source: Source?
  let url: URL?
  let bumped: Date?
  let created: Date?
  let modified: Date?

  var sourceURL: URL? { source?.url ?? url }
  var recencyDate: Date { bumped ?? modified ?? created ?? .distantPast }
  var cacheKey: String {
    "\(id)-\(Int(recencyDate.timeIntervalSince1970 * 1_000))"
  }

  var displayTitle: String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }
    if let name = blob?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return name
    }
    if let body = content?.body {
      let firstLine = body.split(whereSeparator: \Character.isNewline).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let firstLine, !firstLine.isEmpty {
        return String(firstLine.prefix(80))
      }
    }
    if let host = sourceURL?.host(), !host.isEmpty { return host }
    return "Untitled"
  }

  var kind: Kind {
    let entityTypes = mainEntity?.types.map { $0.lowercased() } ?? []
    if entityTypes.contains(where: { $0.contains("image") || $0.contains("photograph") }) {
      return .image
    }
    if entityTypes.contains(where: { $0.contains("video") }) { return .video }
    if entityTypes.contains(where: { $0.contains("article") || $0.contains("web") }) {
      return .article
    }
    if entityTypes.contains(where: { $0.contains("note") }) { return .note }
    if entityTypes.contains(where: { $0.contains("document") || $0.contains("pdf") }) {
      return .document
    }
    if let mime = blob?.type.lowercased() {
      if mime.hasPrefix("image/") { return .image }
      if mime.hasPrefix("video/") { return .video }
      if mime == "application/pdf" { return .document }
      if mime.hasPrefix("text/") { return .note }
      return .file
    }
    if sourceURL != nil { return .article }
    if content != nil { return .note }
    return .object
  }

  enum Kind: Sendable {
    case article
    case image
    case video
    case note
    case document
    case file
    case object

    var displayName: String {
      switch self {
      case .article: "Article"
      case .image: "Image"
      case .video: "Video"
      case .note: "Note"
      case .document: "Document"
      case .file: "File"
      case .object: "Object"
      }
    }

    var symbolName: String {
      switch self {
      case .article: "doc.text"
      case .image: "photo"
      case .video: "play.rectangle"
      case .note: "note.text"
      case .document: "doc.richtext"
      case .file: "doc"
      case .object: "brain"
      }
    }
  }
}

struct MyMindUpload: Sendable {
  enum Body: Sendable {
    case data(Data)
    case file(URL)
  }

  let body: Body
  let filename: String
  let contentType: String
}

enum MyMindCapture: Sendable {
  case url(URL)
  case content(String)
  case upload(MyMindUpload)
}

struct MyMindProblem: Decodable, Sendable {
  let type: String
  let status: Int
  let detail: String
}

enum MyMindAPIError: LocalizedError {
  case credentialsRequired
  case invalidAccessLevel
  case invalidPrivateKey
  case keychainAccessDenied
  case readOnlyKey
  case unauthorized
  case forbidden(String?)
  case rateLimited(resetAfter: TimeInterval?)
  case payloadTooLarge
  case unsupportedMediaType
  case api(status: Int, type: String?, detail: String?)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .credentialsRequired:
      "Add your mymind Key ID and Private Key in extension settings."
    case .invalidAccessLevel:
      "Choose a valid mymind access level in extension settings."
    case .invalidPrivateKey:
      "The mymind Private Key must be valid base64. Copy it again from a newly created access key."
    case .keychainAccessDenied:
      "Tuna could not read the mymind Private Key from Keychain. Allow access or save the key again."
    case .readOnlyKey:
      "Saving requires a Full access mymind key. Update the key and Access Level in extension settings."
    case .unauthorized:
      "mymind rejected the access key. Check the Key ID and Private Key in extension settings."
    case .forbidden(let detail):
      detail ?? "This mymind key does not have permission for that request."
    case .rateLimited(let resetAfter):
      if let resetAfter {
        "mymind's API limit is exhausted. Try again in \(Self.duration(resetAfter))."
      } else {
        "mymind's API limit is exhausted. Try again later."
      }
    case .payloadTooLarge:
      "mymind accepts files up to 64 MB."
    case .unsupportedMediaType:
      "mymind does not support this file format."
    case .api(let status, _, let detail):
      detail ?? "mymind returned HTTP \(status)."
    case .invalidResponse:
      "Could not parse the response from mymind."
    }
  }

  private static func duration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    if interval < 60 {
      formatter.allowedUnits = [.second]
    } else if interval >= 86_400 {
      formatter.allowedUnits = [.day, .hour]
    } else {
      formatter.allowedUnits = [.hour, .minute]
    }
    formatter.unitsStyle = .full
    formatter.maximumUnitCount = 2
    return formatter.string(from: interval) ?? "a while"
  }
}

struct MyMindJWTSigner: Sendable {
  let credentials: MyMindCredentials

  func token(method: String, path: String, now: Date = Date()) throws -> String {
    guard let secret = Data(base64Encoded: credentials.privateKey) else {
      throw MyMindAPIError.invalidPrivateKey
    }
    let issuedAt = Int(now.timeIntervalSince1970)
    let header: [String: Any] = ["alg": "HS256", "kid": credentials.keyID]
    let claims: [String: Any] = [
      "method": method.uppercased(),
      "path": path,
      "iat": issuedAt,
      "exp": issuedAt + 300,
    ]
    let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let unsigned = "\(Self.base64URL(headerData)).\(Self.base64URL(claimsData))"
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(unsigned.utf8),
      using: SymmetricKey(data: secret)
    )
    return "\(unsigned).\(Self.base64URL(Data(signature)))"
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

struct MyMindAPIClient: Sendable {
  static let baseURL = URL(string: "https://api.mymind.com")!
  static let maximumUploadSize: Int64 = 64 * 1_024 * 1_024

  private let credentials: MyMindCredentials
  private let session: URLSession
  private let baseURL: URL
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  init(
    credentials: MyMindCredentials,
    session: URLSession = .shared,
    baseURL: URL = MyMindAPIClient.baseURL
  ) {
    self.credentials = credentials
    self.session = session
    self.baseURL = baseURL
    decoder = Self.makeDecoder()
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
  }

  func listObjects(query: String? = nil, spaceID: String? = nil, limit: Int = 40) async throws
    -> [MyMindObject]
  {
    var queryItems = [
      URLQueryItem(name: "contentAs", value: "text/markdown"),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let query, !query.isEmpty { queryItems.append(URLQueryItem(name: "q", value: query)) }
    if let spaceID { queryItems.append(URLQueryItem(name: "spaceId", value: spaceID)) }
    return try await request(path: "/objects", queryItems: queryItems)
  }

  func listSpaces() async throws -> [MyMindSpace] {
    try await request(path: "/spaces")
  }

  func createObject(_ capture: MyMindCapture, spaceID: String?) async throws -> MyMindObject {
    guard credentials.accessLevel.canWrite else { throw MyMindAPIError.readOnlyKey }
    switch capture {
    case .url(let url):
      return try await request(
        path: "/objects",
        method: "POST",
        body: CreateObjectRequest(url: url.absoluteString, content: nil, spaces: references(spaceID))
      )
    case .content(let value):
      return try await request(
        path: "/objects",
        method: "POST",
        body: CreateObjectRequest(
          url: nil,
          content: MyMindObject.Content(type: "text/markdown", body: value),
          spaces: references(spaceID)
        )
      )
    case .upload(let upload):
      return try await uploadObject(upload, spaceID: spaceID)
    }
  }

  func thumbnail(objectID: String, size: Int) async throws -> Data {
    try await data(
      path: "/objects/\(objectID)/thumbnail",
      queryItems: [URLQueryItem(name: "size", value: "\(size)x\(size)")],
      accept: "image/*"
    ).0
  }

  func content(objectID: String) async throws -> String {
    let result = try await data(
      path: "/objects/\(objectID)/content",
      accept: "text/markdown"
    )
    guard let value = String(data: result.0, encoding: .utf8) else {
      throw MyMindAPIError.invalidResponse
    }
    return value
  }

  func downloadBlob(objectID: String) async throws -> (URL, URLResponse) {
    let request = try makeRequest(path: "/objects/\(objectID)/blob", accept: "*/*")
    let (url, response) = try await session.download(for: request)
    try validate(response: response, data: nil)
    return (url, response)
  }

  func makeRequest(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = [],
    body: Data? = nil,
    contentType: String? = nil,
    accept: String = "application/json"
  ) throws -> URLRequest {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw MyMindAPIError.invalidResponse
    }
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw MyMindAPIError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = method.uppercased()
    request.httpBody = body
    request.setValue("mymind-for-Tuna/0.1", forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue(
      "Bearer \(try MyMindJWTSigner(credentials: credentials).token(method: method, path: path))",
      forHTTPHeaderField: "Authorization"
    )
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    return request
  }

  private func request<Response: Decodable>(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    let result = try await data(path: path, method: method, queryItems: queryItems)
    do {
      return try decoder.decode(Response.self, from: result.0)
    } catch {
      throw MyMindAPIError.invalidResponse
    }
  }

  private func request<Body: Encodable, Response: Decodable>(
    path: String,
    method: String,
    body: Body
  ) async throws -> Response {
    let encoded = try encoder.encode(body)
    let result = try await data(
      path: path,
      method: method,
      body: encoded,
      contentType: "application/json"
    )
    do {
      return try decoder.decode(Response.self, from: result.0)
    } catch {
      throw MyMindAPIError.invalidResponse
    }
  }

  private func data(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = [],
    body: Data? = nil,
    contentType: String? = nil,
    accept: String = "application/json"
  ) async throws -> (Data, URLResponse) {
    let request = try makeRequest(
      path: path,
      method: method,
      queryItems: queryItems,
      body: body,
      contentType: contentType,
      accept: accept
    )
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    return (data, response)
  }

  private func uploadObject(_ upload: MyMindUpload, spaceID: String?) async throws -> MyMindObject {
    let fileData: Data
    switch upload.body {
    case .data(let data):
      fileData = data
    case .file(let url):
      fileData = try Data(contentsOf: url, options: .mappedIfSafe)
    }
    guard fileData.count <= Self.maximumUploadSize else { throw MyMindAPIError.payloadTooLarge }

    let boundary = "Tuna-\(UUID().uuidString)"
    let metadata = try encoder.encode(CreateObjectRequest(
      url: nil,
      content: nil,
      spaces: references(spaceID)
    ))
    var body = Data()
    body.appendUTF8("--\(boundary)\r\n")
    body.appendUTF8("Content-Disposition: form-data; name=\"metadata\"\r\n")
    body.appendUTF8("Content-Type: application/json\r\n\r\n")
    body.append(metadata)
    body.appendUTF8("\r\n--\(boundary)\r\n")
    body.appendUTF8(
      "Content-Disposition: form-data; name=\"blob\"; filename=\"\(Self.quoted(upload.filename))\"\r\n"
    )
    body.appendUTF8("Content-Type: \(upload.contentType)\r\n\r\n")
    body.append(fileData)
    body.appendUTF8("\r\n--\(boundary)--\r\n")

    let result = try await data(
      path: "/objects",
      method: "POST",
      body: body,
      contentType: "multipart/form-data; boundary=\(boundary)"
    )
    do {
      return try decoder.decode(MyMindObject.self, from: result.0)
    } catch {
      throw MyMindAPIError.invalidResponse
    }
  }

  private func validate(response: URLResponse, data: Data?) throws {
    guard let response = response as? HTTPURLResponse else {
      throw MyMindAPIError.api(status: -1, type: nil, detail: nil)
    }
    guard (200..<300).contains(response.statusCode) else {
      let problem = data.flatMap { try? decoder.decode(MyMindProblem.self, from: $0) }
      switch response.statusCode {
      case 401: throw MyMindAPIError.unauthorized
      case 403: throw MyMindAPIError.forbidden(problem?.detail)
      case 413: throw MyMindAPIError.payloadTooLarge
      case 415: throw MyMindAPIError.unsupportedMediaType
      case 429:
        throw MyMindAPIError.rateLimited(
          resetAfter: Self.exhaustedResetInterval(response.value(forHTTPHeaderField: "RateLimit"))
        )
      default:
        throw MyMindAPIError.api(
          status: response.statusCode,
          type: problem?.type,
          detail: problem?.detail
        )
      }
    }
  }

  private func references(_ spaceID: String?) -> [MyMindObject.Reference]? {
    spaceID.map { [MyMindObject.Reference(id: $0)] }
  }

  static func exhaustedResetInterval(_ header: String?) -> TimeInterval? {
    guard let header else { return nil }
    let resets = header.split(separator: ",").compactMap { policy -> TimeInterval? in
      var remaining: Int?
      var reset: Int?
      for component in policy.split(separator: ";").dropFirst() {
        let pair = component.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard pair.count == 2 else { continue }
        if pair[0] == "r" { remaining = Int(pair[1]) }
        if pair[0] == "t" { reset = Int(pair[1]) }
      }
      guard remaining == 0, let reset else { return nil }
      return TimeInterval(reset)
    }
    return resets.max()
  }

  private static func quoted(_ filename: String) -> String {
    filename.replacingOccurrences(of: "\\", with: "_")
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractionalFormatter.date(from: value) { return date }
      let formatter = ISO8601DateFormatter()
      if let date = formatter.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Invalid ISO 8601 timestamp"
      )
    }
    return decoder
  }

  private struct CreateObjectRequest: Encodable {
    let url: String?
    let content: MyMindObject.Content?
    let spaces: [MyMindObject.Reference]?
  }
}

private extension Data {
  mutating func appendUTF8(_ value: String) {
    append(Data(value.utf8))
  }
}
