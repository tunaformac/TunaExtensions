import Foundation
import XCTest

@testable import TunaHue

final class HueGroupTests: XCTestCase {
  func testLoadsRoomsAndZonesWithPowerAndReachability() async throws {
    let groups = try await Self.makeGroupFixtureBridge().groups()
    XCTAssertEqual(groups.count, 3)

    let bedroom = try XCTUnwrap(groups.first { $0.name == "Bedroom" })
    XCTAssertEqual(bedroom.kind, .room)
    XCTAssertEqual(bedroom.isOn, true)
    XCTAssertEqual(bedroom.isOffline, false)

    let kitchen = try XCTUnwrap(groups.first { $0.name == "Kitchen" })
    XCTAssertEqual(kitchen.kind, .room)
    XCTAssertEqual(kitchen.isOn, false)
    XCTAssertEqual(kitchen.isOffline, true, "An accessory without a light should not affect reachability.")

    let downstairs = try XCTUnwrap(groups.first { $0.name == "Downstairs" })
    XCTAssertEqual(downstairs.kind, .zone)
    XCTAssertEqual(downstairs.lightID.uuidString, "00000000-0000-4000-8000-000000000041")
    XCTAssertEqual(downstairs.isOn, true)
    XCTAssertEqual(downstairs.isOffline, false, "The zone has at least one reachable light.")
  }

  func testLoadsRoomsAndZonesWhenZigbeeConnectivityIsUnavailable() async throws {
    let groups = try await Self.makeGroupFixtureBridge(zigbeeStatus: 503).groups()
    XCTAssertEqual(groups.map(\.name).sorted(), ["Bedroom", "Downstairs", "Kitchen"])
    XCTAssertEqual(groups.filter { $0.isOn == true }.map(\.name).sorted(), ["Bedroom", "Downstairs"])
    XCTAssertEqual(groups.filter { $0.isOn == false }.map(\.name), ["Kitchen"])
    for group in groups {
      XCTAssertNil(group.isOffline, "Reachability should be unknown for \(group.name).")
    }
  }

  private static func makeGroupFixtureBridge(zigbeeStatus: Int = 200) throws -> HueBridge {
    try makeHueTestBridge { request in
      guard request.httpMethod == "GET",
            request.value(forHTTPHeaderField: "hue-application-key") == "fixture-key" else {
        return (403, "")
      }
      switch request.url?.path {
      case "/clip/v2/resource/room":
        return (200, """
          {"errors":[],"data":[
            {
              "id":"00000000-0000-4000-8000-000000000010",
              "metadata":{"name":"Bedroom"},
              "children":[{"rid":"00000000-0000-4000-8000-000000000013","rtype":"device"}],
              "services":[{"rid":"00000000-0000-4000-8000-000000000011","rtype":"grouped_light"}]
            },
            {
              "id":"00000000-0000-4000-8000-000000000030",
              "metadata":{"name":"Kitchen"},
              "children":[
                {"rid":"00000000-0000-4000-8000-000000000033","rtype":"device"},
                {"rid":"00000000-0000-4000-8000-000000000034","rtype":"device"}
              ],
              "services":[{"rid":"00000000-0000-4000-8000-000000000031","rtype":"grouped_light"}]
            }
          ]}
          """)
      case "/clip/v2/resource/zone":
        return (200, """
          {"errors":[],"data":[{
            "id":"00000000-0000-4000-8000-000000000040",
            "metadata":{"name":"Downstairs"},
            "children":[
              {"rid":"00000000-0000-4000-8000-000000000032","rtype":"light"},
              {"rid":"00000000-0000-4000-8000-000000000012","rtype":"light"}
            ],
            "services":[{"rid":"00000000-0000-4000-8000-000000000041","rtype":"grouped_light"}]
          }]}
          """)
      case "/clip/v2/resource/grouped_light":
        return (200, """
          {"errors":[],"data":[
            {"id":"00000000-0000-4000-8000-000000000031","on":{"on":false}},
            {"id":"00000000-0000-4000-8000-000000000041","on":{"on":true}},
            {"id":"00000000-0000-4000-8000-000000000011","on":{"on":true}}
          ]}
          """)
      case "/clip/v2/resource/light":
        return (200, """
          {"errors":[],"data":[
            {"id":"00000000-0000-4000-8000-000000000012","owner":{"rid":"00000000-0000-4000-8000-000000000013","rtype":"device"}},
            {"id":"00000000-0000-4000-8000-000000000032","owner":{"rid":"00000000-0000-4000-8000-000000000033","rtype":"device"}}
          ]}
          """)
      case "/clip/v2/resource/zigbee_connectivity":
        guard zigbeeStatus == 200 else { return (zigbeeStatus, "") }
        return (200, """
          {"errors":[],"data":[
            {"owner":{"rid":"00000000-0000-4000-8000-000000000033","rtype":"device"},"status":"disconnected"},
            {"owner":{"rid":"00000000-0000-4000-8000-000000000013","rtype":"device"},"status":"connected"}
          ]}
          """)
      default:
        return (404, "")
      }
    }
  }
}
