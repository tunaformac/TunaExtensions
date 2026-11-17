import AppKit
import Foundation
import TunaKit

/// Every application and compose service, one flat list. Searchable and the contents of the
/// `dokploy` browse root.
public final class DokployServicesCatalog: DokployCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .services)
  }
}

/// Browse root: Dokploy > (server >) project > service.
public final class DokployBrowseCatalog: DokployCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .browse)
  }
}

@MainActor
public class DokployCatalogBase: NSObject, Catalog {
  enum Mode {
    case services
    case browse
  }

  public let identifier: String
  public let name: String
  private let mode: Mode
  private let snapshotStore = LockedValue(DokployScanSnapshot.empty)

  private lazy var rootItem = BrowseCatalogItem(
    title: "Dokploy",
    id: "dokploy-root",
    detail: "Projects and services",
    catalogIcon: .init(symbolName: "shippingbox", color: .indigo)
  ) { [weak self] in
    self?.snapshotStore.readValue { $0.browseChildren() } ?? []
  }

  public var objects: [CatalogItem] {
    let snapshot = snapshotStore.readValue { $0 }
    switch mode {
    case .services:
      return snapshot.services + snapshot.messages
    case .browse:
      return [rootItem]
    }
  }

  fileprivate init(definition: CatalogDefinition, mode: Mode) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.mode = mode
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Dokploy catalog type instead.")
  }

  public func scan() async {
    if RuntimeEnvironment.isRunningTests {
      snapshotStore.value = .empty
      reportScanFinished()
      return
    }

    // Read connections on every scan so URL or key changes apply immediately.
    snapshotStore.value = await DokployScanner.scan(
      connections: DokployConnections.all(),
      savedRecordCount: DokployConnections.recordCount()
    ) { DokployClient(configuration: $0.configuration) }
    reportScanFinished()
  }
}

struct DokployScanSnapshot {
  struct Group {
    let connection: DokployConnection
    let services: [DokployServiceItem]
  }

  var groups: [Group]
  var messages: [CatalogItem]

  static let empty = DokployScanSnapshot(groups: [], messages: [])

  var services: [CatalogItem] { groups.flatMap(\.services) }

  func browseChildren() -> [CatalogItem] {
    let nonEmpty = groups.filter { !$0.services.isEmpty }
    guard nonEmpty.count > 1 else {
      return (nonEmpty.first.map(projectNodes) ?? []) + messages
    }
    return nonEmpty.map { group in
      let projects = projectNodes(for: group)
      return BrowseCatalogItem(
        title: group.connection.displayName,
        id: "server/\(group.connection.recordID)",
        detail: group.connection.configuration.baseURL.host ?? "",
        catalogIcon: .init(symbolName: "server.rack", color: .indigo)
      ) { projects }
    } + messages
  }

  private func projectNodes(for group: Group) -> [CatalogItem] {
    var order: [String] = []
    var byProject: [String: [DokployServiceItem]] = [:]
    for item in group.services {
      if byProject[item.service.projectID] == nil { order.append(item.service.projectID) }
      byProject[item.service.projectID, default: []].append(item)
    }
    return order.compactMap { projectID in
      guard let services = byProject[projectID], let first = services.first else { return nil }
      return BrowseCatalogItem(
        title: first.service.projectName,
        id: "project/\(projectID)",
        detail: services.count == 1 ? "1 service" : "\(services.count) services",
        catalogIcon: .init(symbolName: "folder", color: .blue)
      ) { services }
    }
  }
}

enum DokployScanner {
  /// Loads every connection concurrently. A failing server yields a message item without hiding
  /// services from the others; nothing here throws.
  @MainActor
  static func scan(
    connections: [DokployConnection],
    savedRecordCount: Int,
    makeClient: @escaping @Sendable (DokployConnection) -> any DokployClientProtocol
  ) async -> DokployScanSnapshot {
    guard !connections.isEmpty else {
      let message = savedRecordCount > 0
        ? DokployMessages.incompleteConnection() : DokployMessages.notConfigured()
      return DokployScanSnapshot(groups: [], messages: [message])
    }

    let results = await withTaskGroup(
      of: (Int, Result<[DokployService], Error>).self
    ) { group in
      for (offset, connection) in connections.enumerated() {
        group.addTask {
          do {
            return (offset, .success(try await makeClient(connection).services()))
          } catch {
            return (offset, .failure(error))
          }
        }
      }
      var results: [(Int, Result<[DokployService], Error>)] = []
      for await result in group { results.append(result) }
      return results.sorted { $0.0 < $1.0 }
    }

    let showsConnectionName = connections.count > 1
    var groups: [DokployScanSnapshot.Group] = []
    var messages: [CatalogItem] = []
    for (offset, result) in results {
      let connection = connections[offset]
      switch result {
      case .success(let services):
        let items = services.map {
          DokployServiceItem(
            service: $0, connection: connection, showsConnectionName: showsConnectionName)
        }
        groups.append(.init(connection: connection, services: items))
      case .failure(let error):
        messages.append(
          DokployMessages.failure(
            error, connection: connection, showsConnectionName: showsConnectionName))
      }
    }

    if messages.isEmpty, groups.allSatisfy({ $0.services.isEmpty }) {
      messages.append(DokployMessages.empty())
    }
    return DokployScanSnapshot(groups: groups, messages: messages)
  }
}
