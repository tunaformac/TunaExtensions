import Foundation
import TunaKit

struct ArenaUpload: Sendable {
  enum Body: Sendable {
    case data(Data)
    case file(URL)
  }

  let body: Body
  let filename: String
  let contentType: String
}

struct ArenaConnection: Sendable {
  let record: ExtensionConnectionRecord
  let accessToken: String

  var displayName: String { record.trimmedDisplayName }
  var canWrite: Bool { record.scopes.contains("write") }
}

struct ArenaUser: Sendable {
  let id: Int
  let name: String
  let slug: String
}

struct ArenaChannel: Sendable {
  let id: Int
  let title: String
  let slug: String
  let ownerSlug: String
  let visibility: String
  let updatedAt: Date?

  var url: URL {
    URL(string: "https://www.are.na/\(ownerSlug)/\(slug)")!
  }
}

struct ArenaBlock: Sendable {
  enum Resolution: Sendable {
    case text(String)
    case url(URL)
    case download(url: URL, filename: String?)
  }

  enum Kind: String, Sendable {
    case image = "Image"
    case link = "Link"
    case text = "Text"
    case attachment = "Attachment"
    case embed = "Embed"
    case channel = "Channel"
    case unknown

    var displayName: String {
      switch self {
      case .image: "Image"
      case .link: "Link"
      case .text: "Text"
      case .attachment: "Attachment"
      case .embed: "Embed"
      case .channel: "Channel"
      case .unknown: "Block"
      }
    }

    var symbolName: String {
      switch self {
      case .image: "photo"
      case .link: "link"
      case .text: "text.alignleft"
      case .attachment: "paperclip"
      case .embed: "play.rectangle"
      case .channel: "square.grid.2x2"
      case .unknown: "square"
      }
    }
  }

  let id: Int
  let title: String
  let description: String?
  let kind: Kind
  let sourceURL: URL?
  let imageURL: URL?
  let resolution: Resolution
  let updatedAt: Date?

  var arenaURL: URL { URL(string: "https://www.are.na/block/\(id)")! }
  var openURL: URL { sourceURL ?? arenaURL }
}

enum ArenaAPIError: LocalizedError {
  case invalidToken
  case rateLimited
  case connectionFailures([String])
  case unexpectedStatus(Int, String?)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidToken:
      "Reconnect Are.na in extension settings."
    case .rateLimited:
      "Are.na rate limit reached. Try again later."
    case .connectionFailures(let messages):
      messages.joined(separator: "\n")
    case .unexpectedStatus(let status, let message):
      message ?? "Are.na returned HTTP \(status)."
    case .invalidResponse:
      "Could not parse the Are.na response."
    }
  }
}

struct ArenaAPIClient: Sendable {
  private static let baseURL = URL(string: "https://api.are.na/v3/")!
  private static let dateFormatter = ISO8601DateFormatter()

  private let token: String
  private let session: URLSession

  init(connection: ArenaConnection, session: URLSession = .shared) {
    token = connection.accessToken
    self.session = session
  }

  func fetchCurrentUser() async throws -> ArenaUser {
    let payload = try await get(path: "me")
    guard
      let id = payload["id"] as? Int,
      let name = payload["name"] as? String,
      let slug = payload["slug"] as? String
    else { throw ArenaAPIError.invalidResponse }
    return ArenaUser(id: id, name: name, slug: slug)
  }

  func fetchChannels() async throws -> [ArenaChannel] {
    let user = try await fetchCurrentUser()
    let data = try await fetchAllData(
      path: "users/\(user.slug)/contents",
      queryItems: [
        URLQueryItem(name: "type", value: "Channel"),
        URLQueryItem(name: "sort", value: "updated_at_desc"),
      ]
    )
    let channels = data.compactMap { Self.parseChannel($0, fallbackOwner: user.slug) }

    return channels.sorted {
      let lhs = $0.updatedAt ?? .distantPast
      let rhs = $1.updatedAt ?? .distantPast
      return lhs == rhs
        ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        : lhs > rhs
    }
  }

  func fetchContents(channelSlug: String) async throws -> [ArenaBlock] {
    let data = try await fetchAllData(path: "channels/\(channelSlug)/contents")
    return data.compactMap(Self.parseBlock)
  }

  func createBlock(value: String, channelID: Int) async throws -> ArenaBlock {
    let payload = try await request(
      path: "blocks",
      method: "POST",
      body: ["value": value, "channel_ids": [channelID]]
    )
    guard let block = Self.parseBlock(payload) else { throw ArenaAPIError.invalidResponse }
    return block
  }

  func createBlock(upload: ArenaUpload, channelID: Int) async throws -> ArenaBlock {
    let payload = try await request(
      path: "uploads/presign",
      method: "POST",
      body: [
        "files": [
          ["filename": upload.filename, "content_type": upload.contentType]
        ]
      ]
    )
    guard
      let files = payload["files"] as? [[String: Any]],
      let file = files.first,
      let uploadURLString = file["upload_url"] as? String,
      let uploadURL = URL(string: uploadURLString),
      let key = file["key"] as? String,
      let contentType = file["content_type"] as? String
    else { throw ArenaAPIError.invalidResponse }

    var uploadRequest = URLRequest(url: uploadURL)
    uploadRequest.httpMethod = "PUT"
    uploadRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")

    let response: URLResponse
    switch upload.body {
    case .data(let data):
      (_, response) = try await session.upload(for: uploadRequest, from: data)
    case .file(let url):
      (_, response) = try await session.upload(for: uploadRequest, fromFile: url)
    }
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw ArenaAPIError.unexpectedStatus(status, "Could not upload the image to Are.na.")
    }

    var uploadedURL = URLComponents()
    uploadedURL.scheme = "https"
    uploadedURL.host = "s3.amazonaws.com"
    uploadedURL.path = "/arena_images-temp/\(key.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    guard let value = uploadedURL.url?.absoluteString else {
      throw ArenaAPIError.invalidResponse
    }
    return try await createBlock(value: value, channelID: channelID)
  }

  private func get(path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
    try await request(path: path, queryItems: queryItems)
  }

  private func fetchAllData(
    path: String,
    queryItems: [URLQueryItem] = []
  ) async throws -> [[String: Any]] {
    var page = 1
    var data: [[String: Any]] = []

    while true {
      let payload = try await get(
        path: path,
        queryItems: queryItems + [
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "per", value: "100"),
        ]
      )
      guard let pageData = payload["data"] as? [[String: Any]],
        let meta = payload["meta"] as? [String: Any],
        let hasMore = meta["has_more_pages"] as? Bool
      else { throw ArenaAPIError.invalidResponse }
      data.append(contentsOf: pageData)

      guard hasMore else { return data }
      guard let nextPage = meta["next_page"] as? Int, nextPage > page else {
        throw ArenaAPIError.invalidResponse
      }
      page = nextPage
    }
  }

  private func request(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = [],
    body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    guard var components = URLComponents(
      url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    else { throw ArenaAPIError.invalidResponse }
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw ArenaAPIError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ArenaAPIError.unexpectedStatus(-1, nil)
    }

    guard (200..<300).contains(response.statusCode) else {
      switch response.statusCode {
      case 401: throw ArenaAPIError.invalidToken
      case 403:
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = payload?["message"] as? String
          ?? payload?["error"] as? String
          ?? payload?["title"] as? String
        throw ArenaAPIError.unexpectedStatus(response.statusCode, message)
      case 429: throw ArenaAPIError.rateLimited
      default:
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = payload?["message"] as? String
          ?? payload?["error"] as? String
          ?? payload?["title"] as? String
        throw ArenaAPIError.unexpectedStatus(response.statusCode, message)
      }
    }

    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ArenaAPIError.invalidResponse
    }
    return payload
  }

  private static func parseChannel(
    _ payload: [String: Any], fallbackOwner: String
  ) -> ArenaChannel? {
    guard
      payload["type"] as? String == "Channel",
      let id = payload["id"] as? Int,
      let title = payload["title"] as? String,
      let slug = payload["slug"] as? String
    else { return nil }

    let owner = payload["owner"] as? [String: Any]
    return ArenaChannel(
      id: id,
      title: title,
      slug: slug,
      ownerSlug: owner?["slug"] as? String ?? fallbackOwner,
      visibility: payload["visibility"] as? String ?? "private",
      updatedAt: parseDate(payload["updated_at"] as? String)
    )
  }

  private static func parseBlock(_ payload: [String: Any]) -> ArenaBlock? {
    guard let id = payload["id"] as? Int else { return nil }
    let rawKind = payload["type"] as? String ?? ""
    guard rawKind != "Channel" else { return nil }
    let kind = ArenaBlock.Kind(rawValue: rawKind) ?? .unknown
    let source = payload["source"] as? [String: Any]
    let image = payload["image"] as? [String: Any]
    let imageVariant = image?["small"] as? [String: Any]
    let attachment = payload["attachment"] as? [String: Any]
    let embed = payload["embed"] as? [String: Any]
    let content = payload["content"] as? [String: Any]
    let description = payload["description"] as? [String: Any]
    let sourceURL = (source?["url"] as? String).flatMap(URL.init(string:))
    let imageURL = ((imageVariant?["src"] ?? image?["src"]) as? String).flatMap(URL.init(string:))
    let plainText = content?["plain"] as? String ?? description?["plain"] as? String
    let rawTitle = payload["title"] as? String ?? source?["title"] as? String ?? plainText
    let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

    let arenaURL = URL(string: "https://www.are.na/block/\(id)")!
    let resolution: ArenaBlock.Resolution = switch kind {
    case .image:
      if let url = (image?["src"] as? String).flatMap(URL.init(string:)) {
        .download(url: url, filename: image?["filename"] as? String)
      } else {
        .url(sourceURL ?? arenaURL)
      }
    case .attachment:
      if let url = (attachment?["url"] as? String).flatMap(URL.init(string:)) {
        .download(url: url, filename: attachment?["filename"] as? String)
      } else {
        .url(sourceURL ?? arenaURL)
      }
    case .text:
      if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        .text(plainText)
      } else {
        .url(sourceURL ?? arenaURL)
      }
    case .embed:
      .url(
        sourceURL
          ?? (embed?["source_url"] as? String).flatMap(URL.init(string:))
          ?? (embed?["url"] as? String).flatMap(URL.init(string:))
          ?? arenaURL)
    case .link, .channel, .unknown:
      .url(sourceURL ?? arenaURL)
    }

    return ArenaBlock(
      id: id,
      title: title?.isEmpty == false ? title! : kind.displayName,
      description: plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
      kind: kind,
      sourceURL: sourceURL,
      imageURL: imageURL,
      resolution: resolution,
      updatedAt: parseDate(payload["updated_at"] as? String)
    )
  }

  private static func parseDate(_ value: String?) -> Date? {
    value.flatMap(dateFormatter.date(from:))
  }
}
