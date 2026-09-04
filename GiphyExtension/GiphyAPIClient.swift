import Foundation

struct GiphyGIF: Decodable, Sendable {
  struct Analytics: Decodable, Sendable {
    struct Event: Decodable, Sendable {
      let url: URL
    }

    let onload: Event?
    let onclick: Event?
    let onsent: Event?
  }

  struct Images: Decodable, Sendable {
    struct Rendition: Decodable, Sendable {
      let url: URL
    }

    let fixedWidth: Rendition
    let original: Rendition

    enum CodingKeys: String, CodingKey {
      case fixedWidth = "fixed_width"
      case original
    }
  }

  let id: String
  let title: String
  let altText: String?
  let username: String?
  let pageURL: URL
  let images: Images
  let analytics: Analytics?

  var displayTitle: String {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "GIPHY GIF" : value
  }

  var previewURL: URL { images.fixedWidth.url }
  var originalURL: URL { images.original.url }

  enum CodingKeys: String, CodingKey {
    case id, title, username, images, analytics
    case altText = "alt_text"
    case pageURL = "url"
  }
}

struct GiphyPage: Sendable {
  let gifs: [GiphyGIF]
  let hasMore: Bool
}

enum GiphyAPIError: LocalizedError {
  case queryTooLong
  case invalidAPIKey
  case rateLimited
  case unexpectedStatus(Int, String?)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .queryTooLong:
      "GIPHY searches are limited to 50 characters."
    case .invalidAPIKey:
      "GIPHY rejected this API key. Check it in the extension settings."
    case .rateLimited:
      "GIPHY’s request limit was reached. Try again later."
    case .unexpectedStatus(let status, let message):
      message ?? "GIPHY returned HTTP \(status)."
    case .invalidResponse:
      "GIPHY returned an invalid response."
    }
  }
}

enum GiphyURLSessions {
  static let direct: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()
}

struct GiphyAPIClient: Sendable {
  static let live = GiphyAPIClient()

  private static let pageSize = 25
  private let session: URLSession
  private let baseURL: URL
  private let apiKey: @Sendable () throws -> String
  private let customerID: @Sendable () -> String

  init(
    session: URLSession = GiphyURLSessions.direct,
    baseURL: URL = URL(string: "https://api.giphy.com/v1/gifs")!,
    apiKey: @escaping @Sendable () throws -> String = { GiphySettings.currentAPIKey },
    customerID: @escaping @Sendable () -> String = { GiphyIdentity.customerID }
  ) {
    self.session = session
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.customerID = customerID
  }

  func page(query: String?, page: Int) async throws -> GiphyPage {
    if let query, query.count > 50 { throw GiphyAPIError.queryTooLong }

    let safePage = max(page, 1)
    let offset = (safePage - 1) * Self.pageSize
    let endpoint = baseURL.appending(path: query == nil ? "trending" : "search")
    var components = URLComponents(
      url: endpoint,
      resolvingAgainstBaseURL: false
    )!
    var queryItems = [
      URLQueryItem(name: "api_key", value: try apiKey()),
      URLQueryItem(name: "limit", value: String(Self.pageSize)),
      URLQueryItem(name: "offset", value: String(offset)),
      URLQueryItem(name: "rating", value: GiphySettings.currentRating),
      URLQueryItem(name: "customer_id", value: customerID()),
      URLQueryItem(name: "bundle", value: "messaging_non_clips"),
    ]
    if let query { queryItems.append(URLQueryItem(name: "q", value: query)) }
    components.queryItems = queryItems
    guard let url = components.url else { throw GiphyAPIError.invalidResponse }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw GiphyAPIError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let message = (try? JSONDecoder().decode(GiphyErrorResponse.self, from: data))?.meta.message
      switch response.statusCode {
      case 401, 403: throw GiphyAPIError.invalidAPIKey
      case 429: throw GiphyAPIError.rateLimited
      default: throw GiphyAPIError.unexpectedStatus(response.statusCode, message)
      }
    }

    guard let payload = try? JSONDecoder().decode(GiphyResponse.self, from: data) else {
      throw GiphyAPIError.invalidResponse
    }
    let consumed = payload.pagination.offset + payload.data.count
    return GiphyPage(
      gifs: payload.data,
      hasMore: payload.data.count == Self.pageSize && consumed < payload.pagination.totalCount
    )
  }
}

private enum GiphyIdentity {
  private static let key = "GiphyExtension.CustomerID"

  static let customerID: String = {
    if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
      return saved
    }
    let generated = UUID().uuidString.lowercased()
    UserDefaults.standard.set(generated, forKey: key)
    return generated
  }()
}

enum GiphyAnalyticsEvent: Sendable {
  case appeared
  case activated
  case shared
}

actor GiphyAnalyticsReporter {
  static let live = GiphyAnalyticsReporter()

  private let session: URLSession
  private let customerID: @Sendable () -> String

  init(
    session: URLSession = GiphyURLSessions.direct,
    customerID: @escaping @Sendable () -> String = { GiphyIdentity.customerID }
  ) {
    self.session = session
    self.customerID = customerID
  }

  func report(_ event: GiphyAnalyticsEvent, for gif: GiphyGIF) async {
    await send(event, for: gif)
  }

  private func send(_ event: GiphyAnalyticsEvent, for gif: GiphyGIF) async {
    let eventURL = switch event {
    case .appeared: gif.analytics?.onload?.url
    case .activated: gif.analytics?.onclick?.url
    case .shared: gif.analytics?.onsent?.url
    }
    guard let eventURL, let url = trackingURL(from: eventURL) else { return }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    _ = try? await session.data(for: request)
  }

  func trackingURL(from eventURL: URL, now: Date = .now) -> URL? {
    guard eventURL.scheme == "https", eventURL.host == "giphy-analytics.giphy.com",
      var components = URLComponents(url: eventURL, resolvingAgainstBaseURL: false)
    else { return nil }
    var items = components.percentEncodedQueryItems ?? []
    items.removeAll { $0.name == "customer_id" || $0.name == "ts" }
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=/"))
    guard let encodedCustomerID = customerID().addingPercentEncoding(withAllowedCharacters: allowed)
    else { return nil }
    items.append(URLQueryItem(name: "customer_id", value: encodedCustomerID))
    items.append(URLQueryItem(name: "ts", value: String(Int(now.timeIntervalSince1970 * 1_000))))
    components.percentEncodedQueryItems = items
    return components.url
  }
}

private struct GiphyResponse: Decodable {
  struct Pagination: Decodable {
    let totalCount: Int
    let offset: Int

    enum CodingKeys: String, CodingKey {
      case totalCount = "total_count"
      case offset
    }
  }

  let data: [GiphyGIF]
  let pagination: Pagination
}

private struct GiphyErrorResponse: Decodable {
  struct Meta: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
      case message = "msg"
    }
  }

  let meta: Meta
}
