import Foundation

enum DokployOperation: String, Sendable, CaseIterable {
  case deploy
  case redeploy
  case start
  case stop

  var title: String { rawValue.capitalized }

  /// Present-progressive label for the background task shown while the request is in flight.
  var progressTitle: String {
    switch self {
    case .deploy: "Deploying"
    case .redeploy: "Redeploying"
    case .start: "Starting"
    case .stop: "Stopping"
    }
  }
}

enum DokployAPIError: Error, LocalizedError, Equatable {
  case unauthorized
  case forbidden
  case notFound
  case timedOut
  case unreachable
  case server(status: Int, message: String?)
  case invalidResponse

  var title: String {
    switch self {
    case .unauthorized: "Invalid Dokploy API key"
    case .forbidden: "Dokploy access denied"
    case .notFound: "Not found on Dokploy"
    case .timedOut: "Dokploy timed out"
    case .unreachable: "Dokploy is unreachable"
    case .server, .invalidResponse: "Dokploy request failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case .unauthorized:
      "The API key was rejected. Create a new key in Dokploy under Settings > Profile and update the connection."
    case .forbidden:
      "This API key is not allowed to do that. Check the key's organization and permissions."
    case .notFound:
      "Dokploy could not find this service. Is the URL correct, or was the service deleted?"
    case .timedOut:
      "Dokploy did not respond in time. Check the server and try again."
    case .unreachable:
      "Could not connect to the Dokploy server. Check the URL and your network."
    case .server(let status, let message):
      message.map { "\($0) (HTTP \(status))" } ?? "Dokploy returned HTTP \(status)."
    case .invalidResponse:
      "Dokploy returned a response Tuna could not read. The server may run an unsupported Dokploy version."
    }
  }
}

protocol DokployClientProtocol: Sendable {
  func services() async throws -> [DokployService]
  func perform(_ operation: DokployOperation, on service: DokployService) async throws
  func domains(for service: DokployService) async throws -> [DokployDomain]
}

/// Dokploy's REST API: `GET|POST {baseURL}/api/{router}.{procedure}` with an `x-api-key` header.
struct DokployClient: DokployClientProtocol {
  static let requestTimeout: TimeInterval = 15
  /// application.start / stop wait for Docker before responding.
  static let lifecycleTimeout: TimeInterval = 60

  let configuration: DokployConfiguration
  let session: URLSession

  init(configuration: DokployConfiguration, session: URLSession = .shared) {
    self.configuration = configuration
    self.session = session
  }

  func services() async throws -> [DokployService] {
    let data = try await send(get("project.all"))
    do {
      return try JSONDecoder().decode([DokployProjectPayload].self, from: data).flatMap(\.services)
    } catch {
      throw DokployAPIError.invalidResponse
    }
  }

  func perform(_ operation: DokployOperation, on service: DokployService) async throws {
    let idKey = service.kind == .application ? "applicationId" : "composeId"
    var request = try post("\(service.kind.rawValue).\(operation.rawValue)", body: [idKey: service.id])
    if operation == .start || operation == .stop {
      request.timeoutInterval = Self.lifecycleTimeout
    }
    // Success bodies differ per endpoint (application.deploy returns an empty body), so only the
    // status code matters here.
    _ = try await send(request)
  }

  func domains(for service: DokployService) async throws -> [DokployDomain] {
    let request =
      switch service.kind {
      case .application: get("domain.byApplicationId", query: ["applicationId": service.id])
      case .compose: get("domain.byComposeId", query: ["composeId": service.id])
      }
    do {
      return try JSONDecoder().decode([DokployDomain].self, from: try await send(request))
    } catch let error as DokployAPIError {
      throw error
    } catch {
      throw DokployAPIError.invalidResponse
    }
  }

  // MARK: - Requests

  func get(_ procedure: String, query: [String: String] = [:]) -> URLRequest {
    var components = URLComponents(
      url: endpoint(procedure), resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
    }
    return request(url: components.url!, method: "GET")
  }

  func post(_ procedure: String, body: [String: String]) throws -> URLRequest {
    var request = request(url: endpoint(procedure), method: "POST")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }

  private func endpoint(_ procedure: String) -> URL {
    configuration.baseURL.appendingPathComponent("api").appendingPathComponent(procedure)
  }

  private func request(url: URL, method: String) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw error.code == .timedOut ? DokployAPIError.timedOut : DokployAPIError.unreachable
    } catch {
      throw DokployAPIError.unreachable
    }

    guard let http = response as? HTTPURLResponse else { throw DokployAPIError.invalidResponse }
    switch http.statusCode {
    case 200..<300: return data
    case 401: throw DokployAPIError.unauthorized
    case 403: throw DokployAPIError.forbidden
    case 404: throw DokployAPIError.notFound
    default: throw DokployAPIError.server(status: http.statusCode, message: Self.errorMessage(in: data))
    }
  }

  /// Dokploy/tRPC error bodies look like `{"message": "...", "code": "..."}`.
  static func errorMessage(in data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else { return nil }
    return String(message.prefix(200))
  }
}
