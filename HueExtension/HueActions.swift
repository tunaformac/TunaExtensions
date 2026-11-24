import Foundation
import TunaKit

@MainActor
public final class HueActions: ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = [
    Self.checkConnectionAction(),
    Self.powerAction(id: "on", title: "Turn On", symbol: "lightbulb.fill", on: true),
    Self.powerAction(id: "off", title: "Turn Off", symbol: "lightbulb.slash", on: false),
  ]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func checkConnectionAction() -> CatalogAction {
    let action = PredicateAwareAction(id: "check-connection", title: "Check Connection") { subject, _ in
      guard let item = subject as? HueGroupItem else { return .failure("Choose a Hue room or zone.") }
      do {
        return try await item.checkConnection()
      } catch is CancellationError {
        return .cancelled
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    action.supportedSubjectTypes = [.hueGroup]
    action.subjectPredicate = { ($0 as? HueGroupItem)?.group.isOffline == true }
    action.systemSymbolName = "arrow.clockwise"
    action.executionPolicy = .keepVisible
    return action
  }

  private static func powerAction(id: String, title: String, symbol: String, on: Bool) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard let item = subject as? HueGroupItem else {
        return .failure("Choose a Hue room or zone.")
      }
      let group = item.group
      guard group.isOffline != true else {
        return .failure("All lights in this group are offline.")
      }
      do {
        try await HueConnections.use(item.bridgeID) { bridge in
          try await bridge.setPower(on, lightID: group.lightID)
        }
        item.updatePower(on)
        return .success
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    action.supportedSubjectTypes = [.hueGroup]
    action.subjectPredicate = { subject in
      guard let item = subject as? HueGroupItem else { return false }
      let group = item.group
      return group.isOffline != true && group.isOn != on
    }
    action.systemSymbolName = symbol
    action.executionPolicy = .keepVisible
    return action
  }
}
