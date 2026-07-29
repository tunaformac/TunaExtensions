import Foundation
import TunaKit

public final class ArenaCatalog: Catalog, RescanSchedulingCatalog, StartupScanningCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?

  private let channelsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let deferredLoadState = DeferredCatalogLoadState()

  private lazy var rootItem = BrowseCatalogItem(
    title: "Are.na",
    id: "arena",
    detail: "Your Are.na channels",
    catalogIcon: .init(symbolName: "square.grid.2x2", color: .blue),
    childrenProvider: { [weak self] in self?.browseChildren() ?? [] }
  )

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return message }
    return [rootItem] + channelsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async {
    defer { deferredLoadState.markLoadCompleted() }
    let connections = ArenaCatalogSupport.connections(for: ArenaCatalog.self)
    guard !connections.isEmpty else {
      channelsStore.value = []
      messageStore.value = [ArenaCatalogSupport.authRequiredItem()]
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
      return
    }

    do {
      let results = await withTaskGroup(
        of: (Int, ArenaConnection, [ArenaChannel], String?).self
      ) { group in
        for (offset, connection) in connections.enumerated() {
          group.addTask {
            do {
              return (
                offset,
                connection,
                try await ArenaAPIClient(connection: connection).fetchChannels(),
                nil
              )
            } catch {
              return (offset, connection, [], error.localizedDescription)
            }
          }
        }
        var results: [(Int, ArenaConnection, [ArenaChannel], String?)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }
      }

      let errors = results.compactMap(\.3)
      if errors.count == results.count {
        throw ArenaAPIError.connectionFailures(errors)
      }

      channelsStore.value = results.flatMap { _, connection, channels, _ in
        channels.map {
          ArenaChannelItem(
            channel: $0,
            connection: connection,
            catalogIdentifier: identifier
          )
        }
      }
      messageStore.value = nil
    } catch {
      channelsStore.value = []
      messageStore.value = [ArenaCatalogSupport.errorItem(error)]
    }

    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  public func releaseRetainedState() {
    channelsStore.value = []
    messageStore.value = nil
    deferredLoadState.reset()
  }

  private func browseChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return message }
    deferredLoadState.requestLoadIfNeeded { [weak self] in self?.rescanHandler?() }
    let channels = channelsStore.readValue { $0 }
    if !channels.isEmpty { return channels }
    if deferredLoadState.didCompleteLoad {
      return [
        ArenaCatalogSupport.emptyItem(
          title: "No channels", message: "Create an Are.na channel to see it here.")
      ]
    }
    return [ArenaCatalogSupport.loadingItem()]
  }
}
