import AppKit
import os
import TunaKit

extension TypeID {
  static let hueGroup = TypeID("de.bjesuiter.tuna.type.hue-group")
}

final class ConnectHueBridgeItem: CatalogEntity, Runnable, CommandResultHistoryProviding, @unchecked Sendable {
  private let command: CommandItem
  private let first: Bool
  private let hueIcon: NSImage?

  init(command: CommandItem, first: Bool) {
    self.command = command
    self.first = first
    hueIcon = first ? Bundle(for: HueExtension.self).image(forResource: "HueAlertIcon") : nil
    super.init(id: command.id, title: command.title, path: nil)
    type = command.type
    typeID = command.typeID
  }

  override var detail: String? { command.detail }
  override var searchKeys: [String] {
    first ? command.searchKeys : super.searchKeys + ["Connect Hue Bridge"]
  }
  var headlessEligibility: CommandHeadlessEligibility { command.headlessEligibility }
  var executionPolicy: CommandExecutionPolicy { command.executionPolicy }
  var resultHistoryIdentifier: String? { command.resultHistoryIdentifier }

  func run() async -> ActionResult { await command.run() }

  override func image(size: Int) -> NSImage? {
    hueIcon ?? super.image(size: size)
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    if let hueIcon { return CatalogItemPreview(image: hueIcon) }
    return command.preview(maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    if let hueIcon { return CatalogItemPreview(image: hueIcon) }
    return command.placeholderPreview(maxDimension: maxDimension)
  }
}

final class HueGroupItem: CatalogEntity, @unchecked Sendable {
  let bridgeID: String

  private let bridgeName: String
  private let bridgeLabel: String
  private let state: OSAllocatedUnfairLock<HueGroup>
  private let didCheckConnection: @MainActor (HueGroup) -> Void

  var group: HueGroup { state.withLock { $0 } }

  init(
    group: HueGroup, bridge: HueConnection, bridgeLabel: String,
    didCheckConnection: @escaping @MainActor (HueGroup) -> Void
  ) {
    bridgeID = bridge.id
    bridgeName = bridge.name
    self.bridgeLabel = bridgeLabel
    self.didCheckConnection = didCheckConnection
    state = OSAllocatedUnfairLock(initialState: group)
    super.init(id: "\(bridge.id)/\(group.kind.rawValue)/\(group.id)", title: group.name, path: nil)
    typeID = .hueGroup
  }

  override var detail: String? {
    let group = group
    let location = "\(group.kind.label) · \(bridgeLabel)"
    return group.isOffline == true ? "Offline · \(location)" : location
  }

  func updatePower(_ on: Bool) {
    state.withLock { $0.isOn = on }
  }

  func updateGroup(_ group: HueGroup) {
    state.withLock { $0 = group }
  }

  @MainActor
  func checkConnection() async throws -> ActionResult {
    let selected = group
    let groups = try await HueConnections.use(bridgeID) { bridge in
      try await bridge.groups()
    }
    try Task.checkCancellation()
    guard let latest = groups.first(where: { $0.id == selected.id && $0.kind == selected.kind }) else {
      return .failure("“\(title)” is no longer available on this bridge.")
    }
    guard let isOffline = latest.isOffline else {
      return .failure("Couldn’t confirm whether the lights in “\(title)” are reachable.")
    }
    updateGroup(latest)
    didCheckConnection(latest)
    if isOffline {
      return .failure("All lights in “\(title)” are unreachable. Check that they have power.")
    }
    return .subjects([self])
  }

  override var searchKeys: [String] {
    super.searchKeys + ["Hue", "Hue \(group.name)", "\(bridgeName) \(group.name)"]
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(group.kind == .room ? "lightbulb" : "lightbulb.2", tintColor: .systemOrange)
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    placeholderPreview(maxDimension: maxDimension)
  }
}
