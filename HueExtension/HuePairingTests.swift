import Foundation
import XCTest

@testable import TunaHue

final class HuePairingTests: XCTestCase {
  func testPairingRetriesAfterLinkButtonRequiredAndReturnsApplicationKey() async throws {
    let fixture = PairingFixture()
    let bridge = try makeHueTestBridge(key: nil) { request in
      try await fixture.respond(to: request)
    }

    let key = try await bridge.pair()
    XCTAssertEqual(key, "paired-fixture-key")

    let requests = await fixture.requests
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.url?.path, "/api")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
      XCTAssertNil(request.value(forHTTPHeaderField: "hue-application-key"))
      let body = try XCTUnwrap(request.httpBody)
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
      XCTAssertEqual(payload, ["devicetype": "tuna-hue#mac"])
    }
  }
}

private actor PairingFixture {
  private(set) var requests: [URLRequest] = []

  func respond(to request: URLRequest) throws -> (status: Int, body: String) {
    requests.append(request)
    switch requests.count {
    case 1:
      return (200, #"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#)
    case 2:
      return (200, #"[{"success":{"username":"paired-fixture-key"}}]"#)
    default:
      throw URLError(.badServerResponse)
    }
  }
}
