import Foundation

struct GiphyGIF: Decodable, Sendable {
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

  var displayTitle: String {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "GIPHY GIF" : value
  }

  var previewURL: URL { images.fixedWidth.url }
  var originalURL: URL { images.original.url }

  enum CodingKeys: String, CodingKey {
    case id, title, username, images
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
  case rateLimited
  case unexpectedStatus(Int, String?)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .queryTooLong:
      "GIPHY searches are limited to 50 characters."
    case .rateLimited:
      "GIPHY’s request limit was reached. Try again later."
    case .unexpectedStatus(let status, let message):
      message ?? "GIPHY returned HTTP \(status)."
    case .invalidResponse:
      "GIPHY returned an invalid response."
    }
  }
}

struct GiphyAPIClient: Sendable {
  static let live = GiphyAPIClient()

  private static let pageSize = 25
  private let session: URLSession
  private let baseURL: URL

  init(
    session: URLSession = .shared,
    baseURL: URL = URL(string: "https://tunaformac.com/api/v1/giphy")!
  ) {
    self.session = session
    self.baseURL = baseURL
  }

  func page(query: String?, page: Int) async throws -> GiphyPage {
    if let query, query.count > 50 { throw GiphyAPIError.queryTooLong }

    let safePage = max(page, 1)
    let offset = (safePage - 1) * Self.pageSize
    var components = URLComponents(
      url: baseURL,
      resolvingAgainstBaseURL: false
    )!
    var queryItems = [
      URLQueryItem(name: "limit", value: String(Self.pageSize)),
      URLQueryItem(name: "offset", value: String(offset)),
      URLQueryItem(name: "rating", value: GiphySettings.currentRating),
    ]
    if let query { queryItems.append(URLQueryItem(name: "query", value: query)) }
    components.queryItems = queryItems
    guard let url = components.url else { throw GiphyAPIError.invalidResponse }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw GiphyAPIError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let message = (try? JSONDecoder().decode(GiphyErrorResponse.self, from: data))?.meta.message
      switch response.statusCode {
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
  }

  let meta: Meta
}
