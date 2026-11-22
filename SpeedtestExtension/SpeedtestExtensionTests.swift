import Foundation
import TunaKit
import XCTest

@testable import TunaSpeedtest

final class SpeedtestExtensionTests: XCTestCase {
  override func tearDown() {
    NetworkQuality.runOverride = nil
    super.tearDown()
  }

  @MainActor
  func testDeclaration() throws {
    let instance = try SpeedtestExtension(bundle: Bundle(for: SpeedtestExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.catalogs.map(\.id), ["speedtest"])
    XCTAssertEqual(declaration.catalogs.first?.presentation, .source)
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["speedtest.actions"])
    XCTAssertEqual(declaration.typeRegistrations.first?.inheritsFrom, [.textSnippet])

    let catalog = SpeedtestCatalog(
      definition: CatalogDefinition(
        identifier: "speedtest", name: "Speedtest", enabledByDefault: true, settings: []))
    let command = try XCTUnwrap(catalog.objects.first as? CommandItem)
    XCTAssertEqual(command.title, "Run Speed Test")
    XCTAssertEqual(command.headlessEligibility, .guaranteed)

    let actions = SpeedtestActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "speedtest.actions", name: "Speedtest Actions"))
    XCTAssertEqual(actions.actions.map(\.id), ["copy-summary"])
    XCTAssertEqual(actions.actions.first?.supportedSubjectTypes, [.speedtestResult])
  }

  func testParsesNetworkQualityJSON() throws {
    let result = try NetworkQuality.parse(Self.success(Self.fixture))
    XCTAssertEqual(result.downloadBitsPerSecond, 18_687_442)
    XCTAssertEqual(result.uploadBitsPerSecond, 34_444_120)
    XCTAssertEqual(result.responsivenessRPM ?? 0, 50.839, accuracy: 0.001)
    XCTAssertEqual(result.idleLatencyMilliseconds ?? 0, 201.7, accuracy: 0.1)
    XCTAssertEqual(result.interfaceName, "en0")
    XCTAssertEqual(
      result.summary,
      "Download 18.7 Mbps · Upload 34.4 Mbps · Responsiveness 51 RPM · Idle latency 202 ms")
  }

  func testIgnoresLeadingNoiseAroundJSON() throws {
    let result = try NetworkQuality.parse(Self.success("warning: something\n" + Self.fixture + "\n"))
    XCTAssertEqual(result.interfaceName, "en0")
  }

  func testFailuresAreReported() {
    XCTAssertThrowsError(
      try NetworkQuality.parse(
        CLIProcessResult(exitCode: 1, standardOutput: "", standardError: "No network connection"))
    ) { XCTAssertEqual($0 as? NetworkQualityError, .failed("No network connection")) }

    XCTAssertThrowsError(try NetworkQuality.parse(Self.success(#"{"error_code": -1009}"#))) {
      XCTAssertEqual($0 as? NetworkQualityError, .failed("The speed test did not finish. Error -1009"))
    }

    XCTAssertThrowsError(try NetworkQuality.parse(Self.success("{not json}"))) {
      XCTAssertEqual($0 as? NetworkQualityError, .invalidOutput)
    }
  }

  func testFormatting() {
    XCTAssertEqual(SpeedFormat.bandwidth(940_000), "0.9 Mbps")
    XCTAssertEqual(SpeedFormat.bandwidth(99_960_000), "100.0 Mbps")
    XCTAssertEqual(SpeedFormat.bandwidth(149_500_000), "150 Mbps")
    XCTAssertEqual(SpeedFormat.bandwidth(1_234_000_000), "1.23 Gbps")
    XCTAssertEqual(SpeedFormat.loadedLatency(rpm: 600), "100 ms")
    XCTAssertNil(SpeedFormat.loadedLatency(rpm: 0))
  }

  func testResultItemsCarryCopyableText() throws {
    let result = try NetworkQuality.parse(Self.success(Self.fixture))
    let items = SpeedtestResultItem.items(for: result)
    XCTAssertEqual(
      items.map(\.kind), [.summary, .download, .upload, .responsiveness, .idleLatency])
    XCTAssertEqual(items[1].title, "Download 18.7 Mbps")
    XCTAssertEqual(items[1].textValue, "Download: 18.7 Mbps")
    XCTAssertEqual(items[0].copyRepresentation, result.summary)
    XCTAssertEqual(items[0].detail, "Speed test · en0 · innda3-edge-fx-011.aaplimg.com")
    XCTAssertTrue(items.allSatisfy { $0.typeID == .speedtestResult })
  }

  func testBackgroundTaskReturnsResults() async throws {
    NetworkQuality.runOverride = { request in
      XCTAssertEqual(request.executablePath, "/usr/bin/networkQuality")
      XCTAssertEqual(request.arguments, ["-c", "-M", "60"])
      return Self.success(Self.fixture)
    }
    let completion = await SpeedtestRunner.task().work()
    guard case .success(let results) = completion.disposition else {
      return XCTFail("Expected success")
    }
    XCTAssertEqual(results.count, 5)
    XCTAssertEqual(completion.standardOutput, results.first?.title)
  }

  func testTimeoutAndCancellationReportFailureWithoutResults() async {
    for error in [
      CLIProcessError.timedOut(command: "networkQuality", timeout: 90),
      CLIProcessError.cancelled(command: "networkQuality"),
    ] {
      NetworkQuality.runOverride = { request in
        XCTAssertEqual(request.timeout, 90, "A stalled network can't hang the task")
        throw error
      }
      let completion = await SpeedtestRunner.task().work()
      guard case .failure(let message) = completion.disposition else {
        return XCTFail("Expected failure for \(error)")
      }
      XCTAssertEqual(message, error.localizedDescription)
    }
  }

  static func success(_ output: String) -> CLIProcessResult {
    CLIProcessResult(exitCode: 0, standardOutput: output, standardError: "")
  }

  /// Trimmed real `networkQuality -c` output from macOS 27.
  static let fixture = """
    {
      "base_rtt" : 201.6997528076172,
      "dl_flows" : 15,
      "dl_throughput" : 18687442,
      "il_h2_req_resp" : [171.2, 272.5],
      "interface_name" : "en0",
      "os_version" : "Version 27.2.1 (Build 26B131)",
      "other" : {"protocols_seen" : {"h2" : 153}},
      "responsiveness" : 50.839088439941406,
      "test_endpoint" : "innda3-edge-fx-011.aaplimg.com",
      "ul_flows" : 16,
      "ul_throughput" : 34444120
    }
    """
}
