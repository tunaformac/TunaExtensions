import Foundation

/// Server address and API key for one Dokploy connection. `description` never includes the key.
struct DokployConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let baseURL: URL
  let apiKey: String

  init?(baseURLString: String, apiKey: String) {
    var trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !apiKey.isEmpty else { return nil }
    if !trimmed.contains("://") { trimmed = "https://" + trimmed }
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.lowercased().hasSuffix("/api") { trimmed.removeLast(4) }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", url.host?.isEmpty == false
    else { return nil }
    self.baseURL = url
    self.apiKey = apiKey
  }

  var description: String { "DokployConfiguration(\(baseURL.absoluteString))" }
  var debugDescription: String { description }
}

enum DokployServiceKind: String, Sendable, CaseIterable {
  case application
  case compose

  var displayName: String {
    switch self {
    case .application: "Application"
    case .compose: "Compose"
    }
  }
}

/// One application or compose service, flattened out of `project.all`.
struct DokployService: Sendable, Equatable {
  let kind: DokployServiceKind
  let id: String
  let name: String
  /// `idle`, `running`, `done`, or `error` (Dokploy's applicationStatus / composeStatus).
  let status: String?
  let projectID: String
  let projectName: String
  /// nil on Dokploy releases before v0.25, which had no environments.
  let environmentID: String?
  let environmentName: String?

  /// Stable Tuna item id. Dokploy ids never change when a service is renamed.
  var itemID: String { "\(kind.rawValue)/\(id)" }

  var statusLabel: String? {
    switch status {
    case "idle": "Idle"
    case "running": "Deploying"
    case "done": "Deployed"
    case "error": "Error"
    default: nil
    }
  }

  /// The service page in the Dokploy panel.
  func panelURL(baseURL: URL) -> URL {
    var path = "dashboard/project/\(projectID)"
    if let environmentID { path += "/environment/\(environmentID)" }
    path += "/services/\(kind.rawValue)/\(id)"
    return baseURL.appendingPathComponent(path)
  }
}

struct DokployDomain: Decodable, Sendable, Equatable {
  let host: String
  let https: Bool?
  let path: String?
  let enabled: Bool?

  var url: URL? {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty else { return nil }
    var path = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if path == "/" { path = "" }
    if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
    return URL(string: "\((https ?? false) ? "https" : "http")://\(host)\(path)")
  }

  /// The domain to open or copy: the first enabled one with a usable URL.
  static func primaryURL(in domains: [DokployDomain]) -> URL? {
    domains.first { $0.enabled != false && $0.url != nil }?.url
  }
}

// MARK: - project.all payload

/// Decodes both `project.all` shapes: v0.25+ nests services under `environments`, older
/// releases put `applications` and `compose` directly on the project.
struct DokployProjectPayload: Decodable {
  let projectId: String
  let name: String
  let environments: [Environment]?
  let applications: [Application]?
  let compose: [Compose]?

  struct Environment: Decodable {
    let environmentId: String
    let name: String
    let applications: [Application]?
    let compose: [Compose]?
  }

  struct Application: Decodable {
    let applicationId: String
    let name: String
    let applicationStatus: String?
  }

  struct Compose: Decodable {
    let composeId: String
    let name: String
    let composeStatus: String?
  }

  var services: [DokployService] {
    if let environments {
      return environments.flatMap { environment in
        services(
          applications: environment.applications, compose: environment.compose,
          environmentID: environment.environmentId, environmentName: environment.name)
      }
    }
    return services(
      applications: applications, compose: compose, environmentID: nil, environmentName: nil)
  }

  private func services(
    applications: [Application]?, compose: [Compose]?, environmentID: String?,
    environmentName: String?
  ) -> [DokployService] {
    let apps = (applications ?? []).map {
      DokployService(
        kind: .application, id: $0.applicationId, name: $0.name, status: $0.applicationStatus,
        projectID: projectId, projectName: name, environmentID: environmentID,
        environmentName: environmentName)
    }
    let composes = (compose ?? []).map {
      DokployService(
        kind: .compose, id: $0.composeId, name: $0.name, status: $0.composeStatus,
        projectID: projectId, projectName: name, environmentID: environmentID,
        environmentName: environmentName)
    }
    return apps + composes
  }
}
