import AppKit
import Foundation
import TunaKit

struct SpotifyNowPlaying: Equatable, Sendable {
  enum State: String, Sendable {
    case playing
    case paused
  }

  let state: State
  let uri: String
  let title: String
  let artist: String
  let album: String
  let artworkURL: URL?
}

enum SpotifyScriptError: LocalizedError {
  case notInstalled
  case automationDenied
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "Spotify isn’t installed. Install the Spotify app to control playback from Tuna."
    case .automationDenied:
      return
        "Tuna isn’t allowed to control Spotify. Allow it under Privacy & Security › Automation."
    case .failed(let message):
      return message
    }
  }
}

enum SpotifyAppleScript {
  static let bundleIdentifier = "com.spotify.client"
  static let recordSeparator = "\u{1E}"

  nonisolated(unsafe) static var runOverride: (@Sendable (String) throws -> String)?
  nonisolated(unsafe) static var isSpotifyRunningOverride: (@Sendable () -> Bool)?
  nonisolated(unsafe) static var isInstalledOverride: (@Sendable () -> Bool)?

  /// Without the app, `tell application "Spotify"` would ask the user to locate it.
  static func isInstalled() -> Bool {
    if let isInstalledOverride { return isInstalledOverride() }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  static func isSpotifyRunning() -> Bool {
    if let isSpotifyRunningOverride { return isSpotifyRunningOverride() }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  static func nowPlaying() throws -> SpotifyNowPlaying? {
    guard isSpotifyRunning() else { return nil }
    return parseNowPlaying(try run(Scripts.nowPlaying))
  }

  static func parseNowPlaying(_ output: String) -> SpotifyNowPlaying? {
    let fields = output.components(separatedBy: recordSeparator)
    guard fields.count == 6, let state = SpotifyNowPlaying.State(rawValue: fields[0]) else {
      return nil
    }
    return SpotifyNowPlaying(
      state: state,
      uri: fields[1],
      title: fields[2],
      artist: fields[3],
      album: fields[4],
      artworkURL: URL(string: fields[5])
    )
  }

  static func playPause() throws { try run(Scripts.command("playpause")) }
  static func nextTrack() throws { try run(Scripts.command("next track")) }
  static func previousTrack() throws { try run(Scripts.command("previous track")) }
  static func toggleShuffle() throws {
    try run(Scripts.command("set shuffling to not shuffling"))
  }
  static func toggleRepeat() throws {
    try run(Scripts.command("set repeating to not repeating"))
  }
  static func play(uri: String) throws {
    try run(Scripts.command("play track \(Scripts.literal(uri))"))
  }

  @discardableResult
  static func run(_ source: String) throws -> String {
    guard isInstalled() else { throw SpotifyScriptError.notInstalled }
    if let runOverride { return try runOverride(source) }

    let result: CLIProcessResult
    do {
      result = try CLIProcessRunner.runSync(
        CLIProcessRequest(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
      )
    } catch {
      throw SpotifyScriptError.failed(error.localizedDescription)
    }

    guard result.succeeded else {
      let message = result.preferredErrorMessage
      if message.contains("-1743") || message.contains("Not authorized") {
        throw SpotifyScriptError.automationDenied
      }
      throw SpotifyScriptError.failed(message)
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  enum Scripts {
    static let nowPlaying = """
      set RS to character id 30
      tell application "Spotify"
        set stateText to player state as text
        try
          set t to current track
          return stateText & RS & id of t & RS & name of t & RS & artist of t & RS & album of t & RS & artwork url of t
        on error
          return stateText
        end try
      end tell
      """

    static func command(_ body: String) -> String {
      """
      tell application "Spotify"
        \(body)
      end tell
      """
    }

    static func literal(_ string: String) -> String {
      let escaped =
        string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
      return "\"\(escaped)\""
    }
  }
}
