import Foundation

struct VikunjaProject: Sendable, Equatable {
  let id: Int
  let title: String
  let description: String
  let parentProjectID: Int
  let hexColor: String
  let isArchived: Bool
  let isFavorite: Bool
}

struct VikunjaLabel: Sendable, Equatable {
  let id: Int
  let title: String
  let hexColor: String
}

struct VikunjaTask: Sendable, Equatable {
  let id: Int
  let title: String
  let description: String
  let done: Bool
  let dueDate: Date?
  let priority: Int
  let projectID: Int
  let identifier: String
  let labels: [VikunjaLabel]
  let updatedAt: Date?

  /// Vikunja priorities: higher numbers are more urgent.
  var priorityName: String? {
    switch priority {
    case 1: return "Low"
    case 2: return "Medium"
    case 3: return "High"
    case 4: return "Urgent"
    case 5: return "Do now"
    default: return nil
    }
  }
}

/// Normalizes the user-entered server URL into API and web bases.
struct VikunjaServerConfiguration: Sendable, Equatable {
  let apiBaseURL: URL
  let webBaseURL: URL

  init(baseURLString: String) throws {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VikunjaAPIError.missingServerURL }

    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: withScheme),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else {
      throw VikunjaAPIError.invalidServerURL
    }
    // The API token travels in every request header, so plain HTTP is only allowed on this Mac.
    guard scheme == "https" || Self.isLoopback(host: host) else {
      throw VikunjaAPIError.insecureServerURL
    }

    components.query = nil
    components.fragment = nil
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    if path.lowercased().hasSuffix("/api/v1") {
      path = String(path.dropLast("/api/v1".count))
    }
    components.path = path

    guard let webBaseURL = components.url else { throw VikunjaAPIError.invalidServerURL }
    self.webBaseURL = webBaseURL
    self.apiBaseURL = webBaseURL.appending(path: "api/v1")
  }

  static func isLoopback(host: String) -> Bool {
    let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
  }

  func taskURL(id: Int) -> URL {
    webBaseURL.appending(path: "tasks/\(id)")
  }

  func projectURL(id: Int) -> URL {
    webBaseURL.appending(path: "projects/\(id)")
  }
}

enum VikunjaAPIError: LocalizedError, Equatable {
  case missingConnection
  case missingServerURL
  case invalidServerURL
  case insecureServerURL
  case invalidToken
  case missingScope
  case notFound
  case rateLimited
  case unexpectedStatus(Int, String?)
  case decoding
  case projectNotFound(String)

  var title: String {
    switch self {
    case .missingConnection: return "Connect Vikunja"
    case .missingServerURL: return "Vikunja URL missing"
    case .invalidServerURL: return "Invalid Vikunja URL"
    case .insecureServerURL: return "Vikunja URL must use HTTPS"
    case .invalidToken: return "Invalid Vikunja token"
    case .missingScope: return "Token missing permissions"
    case .notFound: return "Not found in Vikunja"
    case .rateLimited: return "Vikunja rate limit reached"
    case .unexpectedStatus: return "Vikunja request failed"
    case .decoding: return "Vikunja response error"
    case .projectNotFound: return "Default project not found"
    }
  }

  var errorDescription: String? {
    switch self {
    case .missingConnection:
      return "Add a Vikunja connection in extension settings and try again."
    case .missingServerURL:
      return "Enter your Vikunja server URL in the connection settings."
    case .invalidServerURL:
      return "Use a full URL such as https://tasks.example.com."
    case .insecureServerURL:
      return "Your API token would be sent unencrypted over HTTP. Change the URL to https://."
    case .invalidToken:
      return "Update the API token in extension settings and try again."
    case .missingScope:
      return "Create a token with read and write access to Projects and Tasks."
    case .notFound:
      return "The task or project no longer exists."
    case .rateLimited:
      return "Try again in a moment."
    case .unexpectedStatus(let code, let message):
      if let message, !message.isEmpty {
        return "Vikunja returned HTTP \(code): \(message)"
      }
      return "Vikunja returned HTTP \(code)."
    case .decoding:
      return "Could not parse the Vikunja response."
    case .projectNotFound(let name):
      return "No project matches “\(name)”. Change the default project in extension settings."
    }
  }
}

/// A task listing plus whether more matching tasks exist past the fetch limit.
struct VikunjaTaskListing: Sendable, Equatable {
  let tasks: [VikunjaTask]
  let isTruncated: Bool
}

struct VikunjaAPIClient: Sendable {
  static let nullDateString = "0001-01-01T00:00:00Z"
  static let perPage = 50
  /// Task listings stop after this many pages (300 tasks) and report `isTruncated`.
  static let maxTaskPages = 6
  /// Search results stop after this many pages (100 tasks) and report `isTruncated`.
  static let maxSearchPages = 2
  /// Safety stop for listings that should be complete (projects).
  private static let maxPagesUnbounded = 1_000

  let server: VikunjaServerConfiguration
  private let token: String
  private let session: URLSession

  init(connection: VikunjaConnection, session: URLSession = .shared) throws {
    self.token = connection.accessToken
    self.server = try VikunjaServerConfiguration(baseURLString: connection.record.baseURLString)
    self.session = session
  }

  init(server: VikunjaServerConfiguration, token: String, session: URLSession = .shared) {
    self.server = server
    self.token = token
    self.session = session
  }

  // MARK: Projects

  func fetchProjects() async throws -> [VikunjaProject] {
    let (payloads, _) = try await fetchPaged(
      path: "projects", queryItems: [], maxPages: Self.maxPagesUnbounded)
    return payloads.compactMap(Self.parseProject)
      .filter { $0.id > 0 && !$0.isArchived }
  }

  // MARK: Tasks

  private static let openTaskQuery = [
    URLQueryItem(name: "filter", value: "done = false"),
    URLQueryItem(name: "sort_by", value: "due_date"),
    URLQueryItem(name: "order_by", value: "asc"),
  ]

  /// Open tasks across every project the token can see, soonest due first.
  func fetchOpenTasks() async throws -> VikunjaTaskListing {
    try await fetchTaskListing(path: "tasks", queryItems: Self.openTaskQuery, maxPages: Self.maxTaskPages)
  }

  /// Open tasks in one project, soonest due first.
  func fetchOpenTasks(projectID: Int) async throws -> VikunjaTaskListing {
    try await fetchTaskListing(
      path: "projects/\(projectID)/tasks", queryItems: Self.openTaskQuery, maxPages: Self.maxTaskPages)
  }

  /// Server-side text search over open tasks (title and description).
  func searchOpenTasks(query: String) async throws -> VikunjaTaskListing {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return try await fetchOpenTasks() }
    return try await fetchTaskListing(
      path: "tasks",
      queryItems: [URLQueryItem(name: "s", value: trimmed)] + Self.openTaskQuery,
      maxPages: Self.maxSearchPages
    )
  }

  private func fetchTaskListing(
    path: String, queryItems: [URLQueryItem], maxPages: Int
  ) async throws -> VikunjaTaskListing {
    let (payloads, isTruncated) = try await fetchPaged(
      path: path, queryItems: queryItems, maxPages: maxPages)
    return VikunjaTaskListing(tasks: payloads.compactMap(Self.parseTask), isTruncated: isTruncated)
  }

  func fetchTask(id: Int) async throws -> [String: Any] {
    try await requestObject(path: "tasks/\(id)", method: "GET")
  }

  /// Vikunja resets omitted fields on update, so send the full task back with `done` changed.
  func setTaskDone(id: Int, done: Bool) async throws -> VikunjaTask {
    var payload = try await fetchTask(id: id)
    payload["done"] = done
    let updated = try await requestObject(path: "tasks/\(id)", method: "POST", body: payload)
    guard let task = Self.parseTask(updated) else { throw VikunjaAPIError.decoding }
    return task
  }

  func createTask(title: String, projectID: Int) async throws -> VikunjaTask {
    let created = try await requestObject(
      path: "projects/\(projectID)/tasks",
      method: "PUT",
      body: ["title": title]
    )
    guard let task = Self.parseTask(created) else { throw VikunjaAPIError.decoding }
    return task
  }

  func deleteTask(id: Int) async throws {
    _ = try await perform(path: "tasks/\(id)", method: "DELETE", queryItems: [])
  }

  // MARK: Requests

  /// Follows Vikunja's pagination headers. `isTruncated` is true when pages remain after
  /// `maxPages`.
  private func fetchPaged(
    path: String,
    queryItems: [URLQueryItem],
    maxPages: Int
  ) async throws -> (items: [[String: Any]], isTruncated: Bool) {
    var collected: [[String: Any]] = []
    for page in 1...max(1, maxPages) {
      let items = queryItems + [
        URLQueryItem(name: "per_page", value: "\(Self.perPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
      ]
      let (data, response) = try await perform(path: path, method: "GET", queryItems: items)
      guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw VikunjaAPIError.decoding
      }
      collected.append(contentsOf: array)

      let totalPages =
        response.value(forHTTPHeaderField: "x-pagination-total-pages").flatMap(Int.init) ?? 1
      if array.count < Self.perPage || page >= totalPages {
        return (collected, false)
      }
    }
    return (collected, true)
  }

  private func requestObject(
    path: String, method: String, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let (data, _) = try await perform(path: path, method: method, queryItems: [], body: body)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw VikunjaAPIError.decoding
    }
    return object
  }

  private func perform(
    path: String,
    method: String,
    queryItems: [URLQueryItem],
    body: [String: Any]? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    guard
      var components = URLComponents(
        url: server.apiBaseURL.appending(path: path), resolvingAgainstBaseURL: false)
    else { throw VikunjaAPIError.invalidServerURL }
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw VikunjaAPIError.invalidServerURL }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Tuna-Vikunja-Extension", forHTTPHeaderField: "User-Agent")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw VikunjaAPIError.unexpectedStatus(-1, nil)
    }
    guard (200...299).contains(http.statusCode) else {
      throw Self.mapError(status: http.statusCode, data: data)
    }
    return (data, http)
  }

  static func mapError(status: Int, data: Data) -> VikunjaAPIError {
    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let message = payload?["message"] as? String
    switch status {
    case 401: return .invalidToken
    case 403: return .missingScope
    case 404: return .notFound
    case 429: return .rateLimited
    default: return .unexpectedStatus(status, message)
    }
  }

  // MARK: Parsing

  static func parseProject(_ payload: [String: Any]) -> VikunjaProject? {
    guard let id = payload["id"] as? Int, let title = payload["title"] as? String else {
      return nil
    }
    return VikunjaProject(
      id: id,
      title: title,
      description: payload["description"] as? String ?? "",
      parentProjectID: payload["parent_project_id"] as? Int ?? 0,
      hexColor: payload["hex_color"] as? String ?? "",
      isArchived: payload["is_archived"] as? Bool ?? false,
      isFavorite: payload["is_favorite"] as? Bool ?? false
    )
  }

  static func parseTask(_ payload: [String: Any]) -> VikunjaTask? {
    guard let id = payload["id"] as? Int, let title = payload["title"] as? String else {
      return nil
    }
    let labels = (payload["labels"] as? [[String: Any]] ?? []).compactMap { label -> VikunjaLabel? in
      guard let labelID = label["id"] as? Int, let labelTitle = label["title"] as? String else {
        return nil
      }
      return VikunjaLabel(
        id: labelID, title: labelTitle, hexColor: label["hex_color"] as? String ?? "")
    }
    return VikunjaTask(
      id: id,
      title: title,
      description: payload["description"] as? String ?? "",
      done: payload["done"] as? Bool ?? false,
      dueDate: parseDate(payload["due_date"] as? String),
      priority: payload["priority"] as? Int ?? 0,
      projectID: payload["project_id"] as? Int ?? 0,
      identifier: payload["identifier"] as? String ?? "",
      labels: labels,
      updatedAt: parseDate(payload["updated"] as? String)
    )
  }

  private static let dateFormatter = ISO8601DateFormatter()
  private static let fractionalDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Vikunja encodes "no date" as year 1; treat that (and anything unparseable) as nil.
  static func parseDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty, !value.hasPrefix("0001-01-01") else { return nil }
    return dateFormatter.date(from: value) ?? fractionalDateFormatter.date(from: value)
  }
}
