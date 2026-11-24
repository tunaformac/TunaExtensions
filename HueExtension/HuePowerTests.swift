import Foundation
import XCTest

@testable import TunaHue

final class HuePowerTests: XCTestCase {
  func testPowerUpdatesSendBothStatesToTheGroupedLight() async throws {
    let lightID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000011"))
    let requests = PowerRequests()
    let bridge = try makeHueTestBridge { request in
      XCTAssertEqual(request.httpMethod, "PUT")
      XCTAssertEqual(request.url?.path, "/clip/v2/resource/grouped_light/00000000-0000-4000-8000-000000000011")
      XCTAssertEqual(request.value(forHTTPHeaderField: "hue-application-key"), "fixture-key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

      let data = try XCTUnwrap(request.httpBody)
      let update = try JSONDecoder().decode(PowerUpdate.self, from: data)
      await requests.record(update.on.on)
      return (200, #"""
        {"errors":[],"data":[{"rid":"00000000-0000-4000-8000-000000000011","rtype":"grouped_light"}]}
        """#)
    }

    try await bridge.setPower(true, lightID: lightID)
    try await bridge.setPower(false, lightID: lightID)

    let recordedStates = await requests.states
    XCTAssertEqual(recordedStates, [true, false])
  }

  func testPowerUpdatePropagatesBridgeRejection() async throws {
    let lightID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000011"))
    let bridge = try makeHueTestBridge { _ in
      (200, #"""
        {"errors":[{"description":"resource unavailable"}],"data":[]}
        """#)
    }

    do {
      try await bridge.setPower(true, lightID: lightID)
      XCTFail("Expected the bridge rejection to reach the caller")
    } catch HueError.rejected {
      // The bridge can reject a request even when HTTP returns success.
    } catch {
      XCTFail("Expected HueError.rejected, got \(error)")
    }
  }
}

private struct PowerUpdate: Decodable {
  struct State: Decodable {
    let on: Bool
  }

  let on: State
}

private actor PowerRequests {
  private(set) var states: [Bool] = []

  func record(_ state: Bool) {
    states.append(state)
  }
}
