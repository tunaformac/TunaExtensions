import Foundation
import TunaKit
import XCTest

@testable import TunaHue

final class HueActionTests: XCTestCase {
  @MainActor
  func testGroupStateDeterminesAvailableActions() {
    let catalog = HueActions(
      definition: ActionCatalogDefinition(identifier: "hue.actions", name: "Hue Actions")
    )
    let results = catalog.actions.map { action in
      ScoreResult(object: action, score: 1, ranges: [], sourceCatalogIdentifier: catalog.identifier)
    }
    let bridge = HueConnection(address: "hue-bridge.test", id: "001788fffe123456", path: "")
    let cases: [(isOn: Bool, isOffline: Bool, expected: Set<String>)] = [
      (false, false, ["on"]),
      (true, false, ["off"]),
      (false, true, ["check-connection"]),
      (true, true, ["check-connection"]),
    ]

    for state in cases {
      let group = HueGroup(
        id: UUID(), name: "Living Room", kind: .room, lightID: UUID(),
        isOn: state.isOn, isOffline: state.isOffline
      )
      let item = HueGroupItem(group: group, bridge: bridge, bridgeLabel: "Demo Hue Bridge") { _ in }
      let available = SearchResultFiltering.filterActions(
        results, selectedSubject: item, resolvedSubjects: []
      )

      XCTAssertEqual(
        Set(available.map(\.object.id)), state.expected,
        "Power on: \(state.isOn), offline: \(state.isOffline)"
      )
    }
  }
}
