import AppKit
import Foundation
import TunaKit

struct SafariPageInfo: Sendable {
  var title: String?
  var url: URL
}

enum SafariAppleScript {
  static let currentPageToken = RuntimeTokens.safariCurrentPage

  private static let separator = "__TUNA__SEPARATOR__"

  // Injectable for tests.
  static var runOverride: (@Sendable (String) -> String?)?
  static var isSafariRunningOverride: (@Sendable () -> Bool)?

  static func currentPageInfo() -> SafariPageInfo? {
    guard isSafariRunning() else { return nil }
    let script = """
      tell application \"Safari\"
        if (count of windows) is 0 then return \"\"
        set currentTab to current tab of front window
        set pageTitle to name of currentTab
        set pageURL to URL of currentTab
        return pageTitle & \"\(separator)\" & pageURL
      end tell
      """

    guard let output = run(script), !output.isEmpty else { return nil }
    let components = output.components(separatedBy: separator)
    let rawTitle = components.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle?.isEmpty == false ? rawTitle : nil
    let urlString = components.dropFirst().joined(separator: separator)
    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }

    return SafariPageInfo(title: title, url: url)
  }

  static func openNewTab() -> ActionResult {
    let script = """
      tell application \"Safari\"
        activate
        if (count of windows) is 0 then
          make new document
        else
          tell front window to make new tab
        end if
      end tell
      """

    return runCommand(script, failureMessage: "Failed to open a new Safari tab")
  }

  static func openNewPrivateWindow() -> ActionResult {
    let script = """
      tell application \"Safari\"
        activate
        make new document with properties {private:true}
      end tell
      """

    return runCommand(script, failureMessage: "Failed to open a new private Safari window")
  }

  static func isSafariRunning() -> Bool {
    if let isSafariRunningOverride {
      return isSafariRunningOverride()
    }
    return !NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.Safari"
    ).isEmpty
  }

  private static func runCommand(_ source: String, failureMessage: String) -> ActionResult {
    guard run(source) != nil else {
      return .failure(failureMessage)
    }
    return .success
  }

  private static func run(_ source: String) -> String? {
    if let runOverride {
      return runOverride(source)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    do {
      let result = try CLIProcessRunner.runSync(
        CLIProcessRequest(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
      )

      guard result.succeeded else {
        let message = result.preferredErrorMessage
        AppLog.error(
          .actions,
          "Safari AppleScript failed with status \(result.exitCode): \(message)"
        )
        return nil
      }

      return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      AppLog.error(.actions, "Safari AppleScript failed to launch: \(error.localizedDescription)")
      return nil
    }
  }
}
