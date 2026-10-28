import AppKit
import Foundation
import TunaKit

@MainActor
public final class DokployActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  static let serviceTypes: Set<TypeID> = [.dokployApplication, .dokployCompose]

  private static func makeActions() -> [CatalogAction] {
    let lifecycle: [CatalogAction] = [
      operationAction(.deploy, symbol: "arrow.up.circle"),
      operationAction(.redeploy, symbol: "arrow.clockwise.circle"),
      operationAction(.start, symbol: "play.circle"),
      stopAction(),
    ]

    let openInDokploy = action(id: "open-in-dokploy", title: "Open in Dokploy", symbol: "safari") {
      service, connection in
      let url = service.panelURL(baseURL: connection.configuration.baseURL)
      return NSWorkspace.shared.open(url) ? .success : .failure("Could not open \(url.absoluteString)")
    }
    openInDokploy.executionPolicy = .dismiss

    let openDomain = action(id: "open-domain", title: "Open Domain", symbol: "globe") {
      service, connection in
      switch await primaryDomain(of: service, connection: connection) {
      case .success(let url):
        return NSWorkspace.shared.open(url) ? .success : .failure("Could not open \(url.absoluteString)")
      case .failure(let message):
        return .failure(message)
      }
    }
    openDomain.executionPolicy = .resultDriven

    let copyURL = action(id: "copy-url", title: "Copy Domain URL", symbol: "doc.on.doc") {
      service, connection in
      switch await primaryDomain(of: service, connection: connection) {
      case .success(let url):
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(url.absoluteString, forType: .string)
          ? .success : .failure("Could not copy the URL")
      case .failure(let message):
        return .failure(message)
      }
    }
    copyURL.executionPolicy = .resultDriven

    return lifecycle + [openInDokploy, openDomain, copyURL]
  }

  // MARK: - Action builders

  private static func operationAction(_ operation: DokployOperation, symbol: String) -> CatalogAction {
    let action = action(id: operation.rawValue, title: operation.title, symbol: symbol) {
      service, connection in
      .background(backgroundTask(for: operation, service: service, connection: connection))
    }
    action.executionPolicy = .dismiss
    return action
  }

  /// Runs an operation in the background and reports whether Dokploy accepted the request, since
  /// deploy/redeploy/start/stop only queue the job and don't wait for it to finish.
  private static func backgroundTask(
    for operation: DokployOperation, service: DokployService, connection: DokployConnection
  ) -> CommandBackgroundTask {
    CommandBackgroundTask(title: "\(operation.progressTitle) \(service.name)…") {
      switch await run(operation, on: service, connection: connection) {
      case .failure(let message):
        return .failure(message: message)
      default:
        return .successWithoutResult(
          standardOutput: "\(operation.title) request sent for \(service.name). Follow progress with Open in Dokploy."
        )
      }
    }
  }

  private static func stopAction() -> CatalogAction {
    let stop = action(id: DokployOperation.stop.rawValue, title: "Stop", symbol: "stop.circle") {
      service, connection in
      .review(
        ActionReviewSession(
          presentation: ActionReviewPresentation(
            title: "Stop \(service.name)?",
            message: "The \(service.kind.displayName.lowercased()) goes offline until you start or deploy it again.",
            sections: [
              ActionReviewSection(
                id: "service",
                title: service.kind.displayName,
                rows: [
                  ActionReviewRow(
                    id: service.itemID,
                    title: service.name,
                    detail: [service.projectName, service.environmentName]
                      .compactMap { $0 }.joined(separator: " · ")
                  )
                ]
              )
            ],
            confirmButtonTitle: "Stop",
            isDestructive: true
          )
        ) { response in
          guard case .confirm = response else { return .cancelled }
          return await .background(backgroundTask(for: .stop, service: service, connection: connection))
        }
      )
    }
    stop.executionPolicy = .keepVisible
    return stop
  }

  /// Builds an action that only accepts Dokploy services and resolves the item's connection
  /// before calling `body`.
  private static func action(
    id: String, title: String, symbol: String,
    body: @escaping @MainActor @Sendable (DokployService, DokployConnection) async -> ActionResult
  ) -> PredicateAwareAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard let item = subject as? DokployServiceItem else {
        return .failure("Choose a Dokploy application or compose service")
      }
      guard let connection = DokployConnections.connection(recordID: item.connectionRecordID) else {
        return .failure("This Dokploy connection was removed or is incomplete. Check the extension settings.")
      }
      return await body(item.service, connection)
    }
    action.supportedSubjectTypes = serviceTypes
    action.subjectPredicate = { $0 is DokployServiceItem }
    action.systemSymbolName = symbol
    return action
  }

  // MARK: - Operations

  static func run(
    _ operation: DokployOperation, on service: DokployService, connection: DokployConnection,
    client: (any DokployClientProtocol)? = nil
  ) async -> ActionResult {
    let client = client ?? DokployClient(configuration: connection.configuration)
    do {
      try await client.perform(operation, on: service)
      return .success
    } catch {
      return .failure(failureMessage(for: operation, service: service, error: error))
    }
  }

  static func failureMessage(for operation: DokployOperation, service: DokployService, error: Error)
    -> String
  {
    let reason = (error as? LocalizedError)?.errorDescription ?? "Unknown error."
    return "\(operation.title) \(service.name) failed: \(reason)"
  }

  enum DomainLookup: Equatable {
    case success(URL)
    case failure(String)
  }

  static func primaryDomain(
    of service: DokployService, connection: DokployConnection,
    client: (any DokployClientProtocol)? = nil
  ) async -> DomainLookup {
    let client = client ?? DokployClient(configuration: connection.configuration)
    do {
      guard let url = DokployDomain.primaryURL(in: try await client.domains(for: service)) else {
        return .failure("\(service.name) has no domain in Dokploy")
      }
      return .success(url)
    } catch {
      let reason = (error as? LocalizedError)?.errorDescription ?? "Unknown error."
      return .failure("Could not load domains for \(service.name): \(reason)")
    }
  }
}
