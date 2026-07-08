import Foundation

struct GitHubSection<Payload: Sendable>: Sendable {
  let title: String
  let items: [Payload]
}

struct GitHubNotification: Sendable {
  let id: String
  let title: String
  let reason: String
  let repositoryFullName: String
  let subjectType: String
  let isUnread: Bool
  let updatedAt: Date?
  let url: URL
}

struct GitHubIssueOrPullRequest: Sendable {
  let id: Int
  let number: Int
  let title: String
  let repositoryFullName: String
  let state: String
  let updatedAt: Date?
  let url: URL
}

struct GitHubRepository: Sendable {
  let id: Int
  let name: String
  let fullName: String
  let description: String?
  let isPrivate: Bool
  let stargazersCount: Int
  let updatedAt: Date?
  let starredAt: Date?
  let htmlURL: URL

  var sortDate: Date? {
    starredAt ?? updatedAt
  }
}

private struct GitHubServerConfiguration: Sendable {
  let apiBaseURL: URL
  let webBaseURL: URL

  init(baseURLString: String) throws {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawValue = trimmed.isEmpty ? "https://github.com" : trimmed
    guard let rawURL = URL(string: rawValue), rawURL.scheme != nil, rawURL.host != nil else {
      throw GitHubAPIError.invalidServerURL
    }

    var normalizedComponents = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)
    normalizedComponents?.query = nil
    normalizedComponents?.fragment = nil
    let normalizedRawURL = (normalizedComponents?.url ?? rawURL).removingTrailingSlash()
    let trimmedPath = normalizedRawURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let usesExplicitAPIPath = trimmedPath == "api/v3"

    var webComponents = URLComponents(url: normalizedRawURL, resolvingAgainstBaseURL: false)
    webComponents?.query = nil
    webComponents?.fragment = nil
    webComponents?.path = usesExplicitAPIPath ? "" : normalizedRawURL.path
    let webBaseURL = (webComponents?.url ?? normalizedRawURL).removingTrailingSlash()

    if let host = webBaseURL.host?.lowercased(),
      host == "github.com" || host == "www.github.com"
    {
      self.webBaseURL = URL(string: "https://github.com")!
      self.apiBaseURL = URL(string: "https://api.github.com")!
      return
    }

    self.webBaseURL = webBaseURL
    self.apiBaseURL =
      usesExplicitAPIPath
      ? normalizedRawURL.removingTrailingSlash() : webBaseURL.appending(path: "api/v3")
  }
}

enum GitHubAPIError: LocalizedError {
  case missingConnection
  case invalidServerURL
  case invalidToken
  case missingScope
  case notificationsRequireClassicPAT
  case rateLimited(resetAt: Date?)
  case unexpectedStatus(Int)
  case decoding

  var title: String {
    switch self {
    case .missingConnection:
      return "Connect GitHub"
    case .invalidServerURL:
      return "Invalid GitHub URL"
    case .invalidToken:
      return "Invalid GitHub token"
    case .missingScope:
      return "Token missing required scopes"
    case .notificationsRequireClassicPAT:
      return "Notifications require classic PAT"
    case .rateLimited:
      return "GitHub API rate limit reached"
    case .unexpectedStatus:
      return "GitHub request failed"
    case .decoding:
      return "GitHub response error"
    }
  }

  var errorDescription: String? {
    switch self {
    case .missingConnection:
      return "Add at least one GitHub connection in extension settings and try again."
    case .invalidServerURL:
      return "Update the GitHub URL in extension settings and try again."
    case .invalidToken:
      return "Update your token in extension settings and try again."
    case .missingScope:
      return "Use a token with repo, read:org, read:user, and notifications scopes."
    case .notificationsRequireClassicPAT:
      return "GitHub notifications API requires a classic personal access token."
    case .rateLimited(let resetAt):
      if let resetAt {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Try again \(formatter.localizedString(for: resetAt, relativeTo: Date()))."
      }
      return "Try again later."
    case .unexpectedStatus(let code):
      return "GitHub returned HTTP \(code)."
    case .decoding:
      return "Could not parse GitHub response."
    }
  }
}

private struct GitHubErrorResponse: Decodable {
  let message: String
}

private struct GitHubNotificationResponse: Decodable {
  struct Repository: Decodable {
    let fullName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
      case fullName = "full_name"
      case htmlURL = "html_url"
    }
  }

  struct Subject: Decodable {
    let title: String
    let url: URL?
    let type: String
  }

  let id: String
  let unread: Bool
  let reason: String
  let updatedAt: Date?
  let repository: Repository
  let subject: Subject

  enum CodingKeys: String, CodingKey {
    case id
    case unread
    case reason
    case updatedAt = "updated_at"
    case repository
    case subject
  }
}

private struct GitHubSearchResponse: Decodable {
  struct Item: Decodable {
    struct PullRequestMarker: Decodable {}

    let id: Int
    let number: Int
    let title: String
    let repositoryURL: URL
    let state: String
    let updatedAt: Date?
    let htmlURL: URL
    let pullRequest: PullRequestMarker?

    enum CodingKeys: String, CodingKey {
      case id
      case number
      case title
      case repositoryURL = "repository_url"
      case state
      case updatedAt = "updated_at"
      case htmlURL = "html_url"
      case pullRequest = "pull_request"
    }
  }

  let items: [Item]
}

private struct GitHubRepositoryResponse: Decodable {
  let id: Int
  let name: String
  let fullName: String
  let description: String?
  let isPrivate: Bool
  let stargazersCount: Int
  let updatedAt: Date?
  let htmlURL: URL

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case fullName = "full_name"
    case description
    case isPrivate = "private"
    case stargazersCount = "stargazers_count"
    case updatedAt = "updated_at"
    case htmlURL = "html_url"
  }
}

private struct GitHubRepositorySearchResponse: Decodable {
  let items: [GitHubRepositoryResponse]
}

private struct GitHubStarredRepositoryResponse: Decodable {
  let starredAt: Date?
  let repository: GitHubRepositoryResponse

  enum CodingKeys: String, CodingKey {
    case starredAt = "starred_at"
    case repository = "repo"
  }
}

struct GitHubAPIClient {
  private let token: String
  private let server: GitHubServerConfiguration
  private let session: URLSession
  private let decoder: JSONDecoder

  init(connection: GitHubConnection, session: URLSession = .shared) throws {
    self.token = connection.accessToken
    self.server = try GitHubServerConfiguration(baseURLString: connection.record.baseURLString)
    self.session = session

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func fetchUnreadNotifications() async throws -> [GitHubNotification] {
    try await fetchNotifications(includeRead: false)
  }

  func fetchAllNotifications() async throws -> [GitHubNotification] {
    try await fetchNotifications(includeRead: true)
  }

  func fetchMyPullRequests() async throws -> [GitHubSection<GitHubIssueOrPullRequest>] {
    let recentlyClosedSince = Self.isoDate(daysAgo: 14)

    async let open = searchIssueLike(
      query: "is:pr archived:false is:open author:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let assigned = searchIssueLike(
      query: "is:pr archived:false is:open assignee:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let mentioned = searchIssueLike(
      query: "is:pr archived:false is:open mentions:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let reviewRequests = searchIssueLike(
      query: "is:pr archived:false is:open review-requested:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let reviewed = searchIssueLike(
      query: "is:pr archived:false is:open reviewed-by:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let recentlyClosed = searchIssueLike(
      query: "is:pr archived:false is:closed involves:@me closed:>=\(recentlyClosedSince)",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)

    return dedupedSections(
      [
        GitHubSection(title: "Open", items: try await open),
        GitHubSection(title: "Assigned", items: try await assigned),
        GitHubSection(title: "Mentioned", items: try await mentioned),
        GitHubSection(title: "Review Requests", items: try await reviewRequests),
        GitHubSection(title: "Reviewed", items: try await reviewed),
        GitHubSection(title: "Recently Closed", items: try await recentlyClosed),
      ]
    )
  }

  func fetchMyIssues() async throws -> [GitHubSection<GitHubIssueOrPullRequest>] {
    let recentlyClosedSince = Self.isoDate(daysAgo: 60)

    async let created = searchIssueLike(
      query: "is:issue archived:false is:open author:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let assigned = searchIssueLike(
      query: "is:issue archived:false is:open assignee:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let mentioned = searchIssueLike(
      query: "is:issue archived:false is:open mentions:@me",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)
    async let recentlyClosed = searchIssueLike(
      query: "is:issue archived:false is:closed involves:@me closed:>=\(recentlyClosedSince)",
      perPage: Self.searchPerPage,
      maxPages: Self.maxSectionSearchPages)

    return dedupedSections(
      [
        GitHubSection(title: "Created", items: try await created),
        GitHubSection(title: "Assigned", items: try await assigned),
        GitHubSection(title: "Mentioned", items: try await mentioned),
        GitHubSection(title: "Recently Closed", items: try await recentlyClosed),
      ]
    )
  }

  func searchPullRequests(query: String) async throws -> [GitHubIssueOrPullRequest] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return try await searchIssueLike(
      query: "is:pr archived:false involves:@me \(normalized)",
      perPage: Self.searchPerPage,
      maxPages: Self.maxInteractiveSearchPages)
  }

  func searchIssues(query: String) async throws -> [GitHubIssueOrPullRequest] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return try await searchIssueLike(
      query: "is:issue archived:false involves:@me \(normalized)",
      perPage: Self.searchPerPage,
      maxPages: Self.maxInteractiveSearchPages)
  }

  func fetchMyRepositories() async throws -> [GitHubRepository] {
    try await fetchRepositories(
      path: apiURL(path: "user/repos"),
      sort: "updated",
      direction: "desc",
      maxPages: Self.maxRepositoryPages)
  }

  func fetchStarredRepositories() async throws -> [GitHubRepository] {
    // GitHub uses sort=created for "starred at" order (newest stars first).
    var collected: [GitHubRepository] = []

    for page in 1...Self.maxRepositoryPages {
      var components = URLComponents(
        url: apiURL(path: "user/starred"),
        resolvingAgainstBaseURL: false
      )!
      components.queryItems = [
        URLQueryItem(name: "sort", value: "created"),
        URLQueryItem(name: "direction", value: "desc"),
        URLQueryItem(name: "per_page", value: "\(Self.repositoriesPerPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]

      guard let url = components.url else {
        throw GitHubAPIError.unexpectedStatus(-1)
      }

      let response: [GitHubStarredRepositoryResponse] = try await performRequest(
        url: url,
        endpoint: .repositories,
        accept: "application/vnd.github.star+json")
      if response.isEmpty {
        break
      }

      collected.append(
        contentsOf: response.map { entry in
          Self.makeRepository(entry.repository, starredAt: entry.starredAt)
        })
      if response.count < Self.repositoriesPerPage {
        break
      }
    }

    return collected
  }

  func searchMyRepositories(query: String) async throws -> [GitHubRepository] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    let normalizedLower = normalized.lowercased()
    let repositories = try await fetchMyRepositories()
    return repositories.filter { repository in
      repository.name.lowercased().contains(normalizedLower)
        || repository.fullName.lowercased().contains(normalizedLower)
        || (repository.description?.lowercased().contains(normalizedLower) ?? false)
    }
  }

  func searchRepositories(query: String) async throws -> [GitHubRepository] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    var collected: [GitHubRepository] = []

    for page in 1...Self.maxInteractiveSearchPages {
      var components = URLComponents(
        url: apiURL(path: "search/repositories"),
        resolvingAgainstBaseURL: false
      )!
      components.queryItems = [
        URLQueryItem(name: "q", value: normalized),
        URLQueryItem(name: "sort", value: "updated"),
        URLQueryItem(name: "order", value: "desc"),
        URLQueryItem(name: "per_page", value: "\(Self.searchPerPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]

      guard let url = components.url else { break }
      let response: GitHubRepositorySearchResponse = try await performRequest(
        url: url,
        endpoint: .search
      )
      if response.items.isEmpty {
        break
      }

      collected.append(contentsOf: response.items.map { Self.makeRepository($0) })
      if response.items.count < Self.searchPerPage {
        break
      }
    }

    return collected
  }

  private func fetchNotifications(includeRead: Bool) async throws -> [GitHubNotification] {
    var collected: [GitHubNotification] = []
    for page in 1...Self.maxNotificationPages {
      var components = URLComponents(
        url: apiURL(path: "notifications"),
        resolvingAgainstBaseURL: false
      )!
      var queryItems = [
        URLQueryItem(name: "per_page", value: "\(Self.notificationsPerPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]
      if includeRead {
        queryItems.append(URLQueryItem(name: "all", value: "true"))
      }
      components.queryItems = queryItems

      guard let url = components.url else {
        throw GitHubAPIError.unexpectedStatus(-1)
      }

      let response: [GitHubNotificationResponse] = try await performRequest(
        url: url, endpoint: .notifications)
      if response.isEmpty {
        break
      }

      collected.append(
        contentsOf: response.map { item in
          GitHubNotification(
            id: item.id,
            title: item.subject.title,
            reason: item.reason,
            repositoryFullName: item.repository.fullName,
            subjectType: item.subject.type,
            isUnread: item.unread,
            updatedAt: item.updatedAt,
            url: humanURL(fromAPIURL: item.subject.url, repositoryURL: item.repository.htmlURL)
          )
        })

      if response.count < Self.notificationsPerPage {
        break
      }
    }

    return collected
  }

  private func searchIssueLike(query: String, perPage: Int, maxPages: Int) async throws
    -> [GitHubIssueOrPullRequest]
  {
    var collected: [GitHubIssueOrPullRequest] = []

    for page in 1...maxPages {
      var components = URLComponents(
        url: apiURL(path: "search/issues"),
        resolvingAgainstBaseURL: false
      )!
      components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "sort", value: "updated"),
        URLQueryItem(name: "order", value: "desc"),
        URLQueryItem(name: "per_page", value: "\(perPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]

      guard let url = components.url else { break }
      let response: GitHubSearchResponse = try await performRequest(url: url, endpoint: .search)
      if response.items.isEmpty {
        break
      }

      collected.append(
        contentsOf: response.items.map { item in
          GitHubIssueOrPullRequest(
            id: item.id,
            number: item.number,
            title: item.title,
            repositoryFullName: Self.repositoryFullName(from: item.repositoryURL),
            state: item.state,
            updatedAt: item.updatedAt,
            url: item.htmlURL
          )
        })

      if response.items.count < perPage {
        break
      }
    }

    return collected
  }

  private func fetchRepositories(path: URL, sort: String, direction: String, maxPages: Int)
    async throws
    -> [GitHubRepository]
  {
    var collected: [GitHubRepository] = []

    for page in 1...maxPages {
      var components = URLComponents(url: path, resolvingAgainstBaseURL: false)!
      components.queryItems = [
        URLQueryItem(name: "sort", value: sort),
        URLQueryItem(name: "direction", value: direction),
        URLQueryItem(name: "per_page", value: "\(Self.repositoriesPerPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]

      guard let url = components.url else {
        throw GitHubAPIError.unexpectedStatus(-1)
      }

      let response: [GitHubRepositoryResponse] = try await performRequest(
        url: url, endpoint: .repositories)
      if response.isEmpty {
        break
      }

      collected.append(contentsOf: response.map { Self.makeRepository($0) })
      if response.count < Self.repositoriesPerPage {
        break
      }
    }

    return collected
  }

  private func performRequest<Response: Decodable>(
    url: URL,
    endpoint: Endpoint,
    accept: String = "application/vnd.github+json"
  ) async throws
    -> Response
  {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Tuna-GitHub-Extension", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GitHubAPIError.unexpectedStatus(-1)
    }

    guard (200...299).contains(http.statusCode) else {
      throw mapError(data: data, response: http, endpoint: endpoint)
    }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw GitHubAPIError.decoding
    }
  }

  private func mapError(data: Data, response: HTTPURLResponse, endpoint: Endpoint) -> GitHubAPIError
  {
    if response.statusCode == 401 {
      return .invalidToken
    }

    if response.statusCode == 403,
      response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    {
      let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap(TimeInterval.init)
        .map(Date.init(timeIntervalSince1970:))
      return .rateLimited(resetAt: resetAt)
    }

    if response.statusCode == 403 || response.statusCode == 404 {
      let message =
        (try? decoder.decode(GitHubErrorResponse.self, from: data))?.message.lowercased() ?? ""
      if endpoint == .notifications,
        message.contains("fine-grained") || message.contains("personal access token")
      {
        return .notificationsRequireClassicPAT
      }
      if message.contains("resource not accessible")
        || message.contains("insufficient")
        || message.contains("must have")
      {
        return .missingScope
      }
    }

    return .unexpectedStatus(response.statusCode)
  }

  private func dedupedSections(_ sections: [GitHubSection<GitHubIssueOrPullRequest>])
    -> [GitHubSection<GitHubIssueOrPullRequest>]
  {
    var seen = Set<Int>()
    var result: [GitHubSection<GitHubIssueOrPullRequest>] = []

    for section in sections {
      let uniqueItems = section.items.filter { item in
        if seen.contains(item.id) {
          return false
        }
        seen.insert(item.id)
        return true
      }

      if !uniqueItems.isEmpty {
        result.append(GitHubSection(title: section.title, items: uniqueItems))
      }
    }

    return result
  }

  private static func makeRepository(
    _ response: GitHubRepositoryResponse,
    starredAt: Date? = nil
  ) -> GitHubRepository {
    GitHubRepository(
      id: response.id,
      name: response.name,
      fullName: response.fullName,
      description: response.description,
      isPrivate: response.isPrivate,
      stargazersCount: response.stargazersCount,
      updatedAt: response.updatedAt,
      starredAt: starredAt,
      htmlURL: response.htmlURL
    )
  }

  private static func repositoryFullName(from repositoryURL: URL) -> String {
    let components = repositoryURL.pathComponents.filter { $0 != "/" }
    guard let reposIndex = components.firstIndex(of: "repos"), reposIndex + 2 < components.count
    else {
      return repositoryURL.absoluteString
    }
    return "\(components[reposIndex + 1])/\(components[reposIndex + 2])"
  }

  private func humanURL(fromAPIURL apiURL: URL?, repositoryURL: URL) -> URL {
    guard let apiURL else { return repositoryURL }

    let path = apiURL.path
    if path.contains("/pulls/") {
      return transformedGitHubURL(apiURL: apiURL, replacing: "/pulls/", with: "/pull/")
    }
    if path.contains("/issues/") {
      return transformedGitHubURL(apiURL: apiURL, replacing: "/issues/", with: "/issues/")
    }
    if path.contains("/discussions/") {
      return transformedGitHubURL(apiURL: apiURL, replacing: "/discussions/", with: "/discussions/")
    }
    if path.contains("/commits/") {
      return transformedGitHubURL(apiURL: apiURL, replacing: "/commits/", with: "/commit/")
    }

    return repositoryURL
  }

  private func transformedGitHubURL(apiURL: URL, replacing source: String, with destination: String)
    -> URL
  {
    var path = apiURL.path
    if path.hasPrefix("/api/v3/repos/") {
      path = String(path.dropFirst("/api/v3/repos".count))
    } else if path.hasPrefix("/repos/") {
      path = String(path.dropFirst("/repos".count))
    }
    path = path.replacingOccurrences(of: source, with: destination)
    var components = URLComponents(url: server.webBaseURL, resolvingAgainstBaseURL: false)
    components?.path = path
    return components?.url ?? apiURL
  }

  private func apiURL(path: String) -> URL {
    server.apiBaseURL.appending(path: path)
  }

  private static func isoDate(daysAgo: Int) -> String {
    let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    return dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let notificationsPerPage = 50
  private static let repositoriesPerPage = 100
  private static let searchPerPage = 50

  private static let maxNotificationPages = 5
  private static let maxRepositoryPages = 10
  private static let maxSectionSearchPages = 2
  private static let maxInteractiveSearchPages = 4

  private enum Endpoint {
    case notifications
    case search
    case repositories
  }
}

extension URL {
  fileprivate func removingTrailingSlash() -> URL {
    guard absoluteString.hasSuffix("/") else { return self }
    return URL(string: String(absoluteString.dropLast())) ?? self
  }
}
