import Foundation
import XCTest

@testable import TunaHue

final class HueRecoveryTests: XCTestCase {
  @MainActor
  func testRetriesMatchingBridgeAtNewAddressWithCurrentKeyAndSavesAfterSuccess() async throws {
    let fixture = RecoveryFixture()

    try await fixture.setPower(
      duringDiscovery: { $0.key = "new-key" },
      beforeRetryResponse: { XCTAssertEqual($0.record?.address, RecoveryFixture.oldAddress) }
    )

    XCTAssertEqual(fixture.attempts, [
      .init(host: RecoveryFixture.oldAddress, key: "old-key"),
      .init(host: RecoveryFixture.newAddress, key: "new-key"),
    ])
    XCTAssertEqual(fixture.record?.address, RecoveryFixture.newAddress)
  }

  @MainActor
  func testKeepsSavedAddressWhenRetryFails() async throws {
    let fixture = RecoveryFixture()
    let original = fixture.record

    do {
      try await fixture.setPower(beforeRetryResponse: { _ in throw URLError(.notConnectedToInternet) })
      XCTFail("Expected the failed retry to reach the caller.")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .notConnectedToInternet)
    }

    XCTAssertEqual(fixture.attempts.map(\.host), [RecoveryFixture.oldAddress, RecoveryFixture.newAddress])
    XCTAssertEqual(fixture.record, original)
  }

  @MainActor
  func testDoesNotRestoreBridgeDisconnectedDuringSuccessfulRetry() async throws {
    let fixture = RecoveryFixture()

    try await fixture.setPower(beforeRetryResponse: { $0.record = nil })

    XCTAssertEqual(fixture.attempts.map(\.host), [RecoveryFixture.oldAddress, RecoveryFixture.newAddress])
    XCTAssertNil(fixture.record)
  }

  @MainActor
  func testDoesNotRetryWhenBridgeWasReconnectedDuringDiscovery() async throws {
    let fixture = RecoveryFixture()
    let replacement = HueConnection(address: "192.0.2.30", id: RecoveryFixture.id, path: "")

    do {
      try await fixture.setPower(duringDiscovery: { $0.record = replacement })
      XCTFail("Expected the outdated request to stop after discovery.")
    } catch HueError.disconnected {
      XCTAssertEqual(fixture.attempts.map(\.host), [RecoveryFixture.oldAddress])
      XCTAssertEqual(fixture.record, replacement)
    }
  }
}

@MainActor
private final class RecoveryFixture {
  static let id = "001788fffe123456"
  static let oldAddress = "192.0.2.10"
  static let newAddress = "192.0.2.20"

  struct Attempt: Equatable {
    let host: String?
    let key: String?
  }

  var record: HueConnection? = HueConnection(address: oldAddress, id: id, path: "")
  var key = "old-key"
  private(set) var attempts: [Attempt] = []

  func setPower(
    duringDiscovery: @escaping @MainActor (RecoveryFixture) -> Void = { _ in },
    beforeRetryResponse: @escaping @MainActor (RecoveryFixture) throws -> Void = { _ in }
  ) async throws {
    let lightID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000011"))
    let access = HueConnections.Access(
      record: { self.record?.id == $0 ? self.record : nil },
      key: { self.record?.id == $0 ? self.key : nil },
      discover: {
        duringDiscovery(self)
        return [
          DiscoveredHueBridge(id: "001788fffe654321", internalipaddress: "192.0.2.40"),
          DiscoveredHueBridge(id: Self.id.uppercased(), internalipaddress: Self.newAddress),
        ]
      },
      client: { record, key in
        try HueBridge(address: record.address, id: record.id, key: key, caPEM: hueRootCertificates) { request in
          try await self.respond(to: request, beforeRetryResponse: beforeRetryResponse)
        }
      },
      saveChanges: { _, updated in self.record = updated }
    )
    try await HueConnections.use(Self.id, access: access) { bridge in
      try await bridge.setPower(true, lightID: lightID)
    }
  }

  private func respond(
    to request: URLRequest, beforeRetryResponse: @MainActor (RecoveryFixture) throws -> Void
  ) throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    attempts.append(.init(host: url.host, key: request.value(forHTTPHeaderField: "hue-application-key")))
    if url.host == Self.oldAddress { throw URLError(.timedOut) }
    try beforeRetryResponse(self)
    let data = Data(#"{"errors":[],"data":[{"rid":"00000000-0000-4000-8000-000000000011","rtype":"grouped_light"}]}"#.utf8)
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    return (data, response)
  }
}
