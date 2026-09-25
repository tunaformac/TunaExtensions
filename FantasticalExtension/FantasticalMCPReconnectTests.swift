import XCTest

@testable import TunaFantastical

final class FantasticalMCPReconnectTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Answers `initialize`, then replies to every tool call with `firstLaunchError` on the first
  /// launch and with a real result on any later one. Each launch appends a line to `launches`.
  private func makeHelper(firstLaunchError: String) throws -> URL {
    let script = """
      #!/bin/sh
      echo launch >> "\(directory.path)/launches"
      count=$(wc -l < "\(directory.path)/launches" | tr -d ' ')
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
        [ -z "$id" ] && continue
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
          *)
            if [ "$count" = 1 ]; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"\(firstLaunchError)"}]}}\\n' "$id"
            else
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"fresh agenda"}]}}\\n' "$id"
            fi ;;
        esac
      done
      """
    let url = directory.appending(path: "helper")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func launchCount() throws -> Int {
    let log = try String(contentsOf: directory.appending(path: "launches"), encoding: .utf8)
    return log.split(separator: "\n").count
  }

  func testStrandedHelperIsReplacedAndTheCallRetriedOnce() async throws {
    let helper = try makeHelper(firstLaunchError: "Failed to connect to Fantastical.")
    let client = FantasticalMCPClient(locateHelper: { helper })

    let result = try await client.call("queryCalendars")
    await client.shutdown()

    XCTAssertEqual(result.text, "fresh agenda")
    XCTAssertEqual(try launchCount(), 2)
  }

  func testOtherToolErrorsAreNotRetried() async throws {
    let helper = try makeHelper(firstLaunchError: "some other error")
    let client = FantasticalMCPClient(locateHelper: { helper })

    do {
      _ = try await client.call("queryCalendars")
      XCTFail("expected the tool error")
    } catch {
      XCTAssertEqual(error as? FantasticalMCPError, .tool("some other error"))
    }
    await client.shutdown()

    XCTAssertEqual(try launchCount(), 1)
  }

  func testStrandedHelperTextIsRecognised() {
    XCTAssertTrue(FantasticalMCPClient.isStrandedHelper("Error: Failed to connect to Fantastical."))
    XCTAssertFalse(FantasticalMCPClient.isStrandedHelper("some other error"))
  }
}
