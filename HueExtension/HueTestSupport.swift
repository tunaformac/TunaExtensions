import Foundation
import XCTest

@testable import TunaHue

func makeHueTestBridge(
  key: String? = "fixture-key",
  handler: @escaping @Sendable (URLRequest) async throws -> (status: Int, body: String)
) throws -> HueBridge {
  try HueBridge(
    address: "hue-bridge.test", id: "001788fffe123456", key: key, caPEM: hueRootCertificates
  ) { request in
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "hue-bridge.test")
    let fixture = try await handler(request)
    let response = try XCTUnwrap(HTTPURLResponse(
      url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    ))
    return (Data(fixture.body.utf8), response)
  }
}
