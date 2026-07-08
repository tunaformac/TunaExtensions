import Foundation

struct NotionItem: Sendable {
  enum Kind: String, Sendable {
    case page
    case dataSource = "data_source"
    case database
    case unknown

    var displayName: String {
      switch self {
      case .page:
        return "Page"
      case .dataSource:
        return "Data Source"
      case .database:
        return "Database"
      case .unknown:
        return "Result"
      }
    }

    var symbolName: String {
      switch self {
      case .page:
        return "doc.text"
      case .dataSource, .database:
        return "tablecells"
      case .unknown:
        return "book.pages"
      }
    }
  }

  enum Icon: Sendable {
    case emoji(String)
    case imageURL(URL)
  }

  let id: String
  let title: String
  let url: URL
  let kind: Kind
  let lastEditedAt: Date?
  let icon: Icon?
  let parentType: String?

  var isTopLevelPage: Bool {
    kind == .page && parentType == "workspace"
  }
}

enum NotionAPIError: LocalizedError {
  case missingConnection
  case invalidToken
  case missingReadContentCapability
  case rateLimited
  case unexpectedStatus(Int)
  case decoding

  var title: String {
    switch self {
    case .missingConnection:
      return "Connect Notion"
    case .invalidToken:
      return "Invalid Notion connection"
    case .missingReadContentCapability:
      return "Notion integration missing permissions"
    case .rateLimited:
      return "Notion API rate limit reached"
    case .unexpectedStatus:
      return "Notion request failed"
    case .decoding:
      return "Notion response error"
    }
  }

  var errorDescription: String? {
    switch self {
    case .missingConnection:
      return "Add at least one Notion connection in extension settings and try again."
    case .invalidToken:
      return "Reconnect Notion in extension settings and try again."
    case .missingReadContentCapability:
      return "Enable the Read content capability for your Notion integration, then reconnect."
    case .rateLimited:
      return "Try again later."
    case .unexpectedStatus(let code):
      return "Notion returned HTTP \(code)."
    case .decoding:
      return "Could not parse the Notion response."
    }
  }
}

struct NotionAPIClient {
  private static let notionVersion = "2025-09-03"
  private static let dateFormatter = ISO8601DateFormatter()
  private static let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Hard cap on the number of sequential paginated requests issued while hunting for
  /// top-level pages. The search API only returns a `parent.type` we can filter on
  /// client-side, sorted by recency rather than by top-level-ness, so a workspace with many
  /// recently-edited sub-pages ahead of its top-level pages can require several pages of
  /// results before enough top-level pages are found. This bounds worst-case API cost (and
  /// latency) on very large/noisy workspaces instead of paginating indefinitely.
  private static let topLevelPagesMaxRequestPages = 10
  /// Hard cap on the total number of raw search results scanned across all paginated
  /// requests for top-level pages, for the same reason as `topLevelPagesMaxRequestPages`.
  private static let topLevelPagesMaxItemsScanned = 1000

  private let token: String
  private let session: URLSession

  init(connection: NotionConnection, session: URLSession = .shared) {
    self.token = connection.accessToken
    self.session = session
  }

  /// Single request only: this backs the "Recently edited" root view, which wants the
  /// N most-recently-edited items. The API already sorts by `last_edited_time` descending,
  /// so the first page *is* the most recent N items by definition — there is nothing
  /// further pages could contribute that wouldn't be less recent, so pagination here would
  /// only add latency and API calls with no benefit.
  func fetchRecentItems(limit: Int = 25) async throws -> [NotionItem] {
    try await search(query: nil, limit: limit)
  }

  /// Fetches up to `limit` top-level (workspace-parented) pages, paginating through the
  /// search API with `start_cursor`/`has_more` as needed. Unlike the other search helpers
  /// below, a single request is not sufficient here: the search API sorts by recency, not
  /// by `parent.type`, so top-level pages can be interleaved with (or pushed behind) many
  /// non-top-level shared pages — in a workspace with more than 100 shared pages, a single
  /// page of results is not guaranteed to contain every top-level page. Pagination stops
  /// early once `limit` top-level pages have been found, or once the safety caps above are
  /// hit.
  func fetchTopLevelPages(limit: Int = 100) async throws -> [NotionItem] {
    let targetCount = max(1, limit)
    var collected: [NotionItem] = []
    var cursor: String?
    var itemsScanned = 0

    for _ in 0..<Self.topLevelPagesMaxRequestPages {
      let (items, hasMore, nextCursor) = try await performSearchRequest(
        query: nil,
        pageSize: max(1, min(targetCount, 100)),
        objectFilter: .page,
        startCursor: cursor
      )

      itemsScanned += items.count
      collected.append(contentsOf: items.filter(\.isTopLevelPage))

      if collected.count >= targetCount { break }
      guard hasMore, let nextCursor, itemsScanned < Self.topLevelPagesMaxItemsScanned else {
        break
      }
      cursor = nextCursor
    }

    return Array(collected.prefix(targetCount))
  }

  /// Single request only: interactive (debounced, re-run on every keystroke) text search.
  /// Notion ranks text-query results by relevance, so truncating to one page of up to 20
  /// results is the intended UX (a short, fast result list), not a completeness bug — and
  /// paginating on every keystroke would multiply API calls for no user-visible benefit.
  func searchPages(query: String?, limit: Int = 20) async throws -> [NotionItem] {
    try await search(query: query, limit: limit, objectFilter: .page)
  }

  /// Single request only: same interactive-search rationale as `searchPages`.
  func search(query: String?, limit: Int = 20) async throws -> [NotionItem] {
    try await search(query: query, limit: limit, objectFilter: nil)
  }

  /// Single-request search, used by callers that intentionally only want one page of
  /// results (see per-call-site rationale on `fetchRecentItems`, `searchPages`, `search`).
  private func search(query: String?, limit: Int, objectFilter: NotionItem.Kind?) async throws
    -> [NotionItem]
  {
    let (items, _, _) = try await performSearchRequest(
      query: query, pageSize: limit, objectFilter: objectFilter, startCursor: nil)
    return items
  }

  private func performSearchRequest(
    query: String?, pageSize: Int, objectFilter: NotionItem.Kind?, startCursor: String?
  ) async throws -> (items: [NotionItem], hasMore: Bool, nextCursor: String?) {
    var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    request.httpBody = try JSONSerialization.data(
      withJSONObject: requestBody(
        query: query, limit: pageSize, objectFilter: objectFilter, startCursor: startCursor)
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NotionAPIError.unexpectedStatus(-1)
    }

    switch httpResponse.statusCode {
    case 200:
      break
    case 401:
      throw NotionAPIError.invalidToken
    case 403:
      throw NotionAPIError.missingReadContentCapability
    case 429:
      throw NotionAPIError.rateLimited
    default:
      throw NotionAPIError.unexpectedStatus(httpResponse.statusCode)
    }

    guard
      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawResults = payload["results"] as? [[String: Any]]
    else {
      throw NotionAPIError.decoding
    }

    let hasMore = payload["has_more"] as? Bool ?? false
    let nextCursor = payload["next_cursor"] as? String

    return (rawResults.compactMap(Self.parseItem), hasMore, nextCursor)
  }

  private func requestBody(
    query: String?, limit: Int, objectFilter: NotionItem.Kind?, startCursor: String? = nil
  ) -> [String: Any] {
    var body: [String: Any] = [
      "page_size": max(1, min(limit, 100)),
      "sort": [
        "timestamp": "last_edited_time",
        "direction": "descending",
      ],
    ]

    if let query {
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        body["query"] = trimmed
      }
    }

    if let objectFilter {
      body["filter"] = [
        "property": "object",
        "value": objectFilter.rawValue,
      ]
    }

    if let startCursor {
      body["start_cursor"] = startCursor
    }

    return body
  }

  private static func parseItem(_ payload: [String: Any]) -> NotionItem? {
    let kind = NotionItem.Kind(rawValue: payload["object"] as? String ?? "") ?? .unknown
    guard let id = payload["id"] as? String else { return nil }
    guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
      return nil
    }

    let title = extractTitle(from: payload)
    let lastEditedAt = parseDate(payload["last_edited_time"] as? String)
    let parent = payload["parent"] as? [String: Any]

    return NotionItem(
      id: id,
      title: title.isEmpty ? "Untitled" : title,
      url: url,
      kind: kind,
      lastEditedAt: lastEditedAt,
      icon: extractIcon(from: payload),
      parentType: parent?["type"] as? String
    )
  }

  private static func parseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    return fractionalSecondsDateFormatter.date(from: string) ?? dateFormatter.date(from: string)
  }

  private static func extractIcon(from payload: [String: Any]) -> NotionItem.Icon? {
    guard let icon = payload["icon"] as? [String: Any], let type = icon["type"] as? String else {
      return nil
    }

    switch type {
    case "emoji":
      guard let emoji = icon["emoji"] as? String, !emoji.isEmpty else { return nil }
      return .emoji(emoji)
    case "external":
      guard
        let external = icon["external"] as? [String: Any],
        let urlString = external["url"] as? String,
        let url = URL(string: urlString)
      else { return nil }
      return .imageURL(url)
    case "file":
      guard
        let file = icon["file"] as? [String: Any],
        let urlString = file["url"] as? String,
        let url = URL(string: urlString)
      else { return nil }
      return .imageURL(url)
    default:
      return nil
    }
  }

  private static func extractTitle(from payload: [String: Any]) -> String {
    if let title = richTextPlainText(payload["title"]) {
      return title
    }

    if let properties = payload["properties"] as? [String: [String: Any]],
      let titleProperty = properties.values.first(where: { ($0["type"] as? String) == "title" }),
      let title = richTextPlainText(titleProperty["title"])
    {
      return title
    }

    return ""
  }

  private static func richTextPlainText(_ rawValue: Any?) -> String? {
    guard let values = rawValue as? [[String: Any]] else { return nil }

    let parts = values.compactMap { value -> String? in
      if let plainText = value["plain_text"] as? String, !plainText.isEmpty {
        return plainText
      }

      if let text = value["text"] as? [String: Any],
        let content = text["content"] as? String,
        !content.isEmpty
      {
        return content
      }

      return nil
    }

    let title = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }
}
