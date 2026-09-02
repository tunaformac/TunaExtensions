import AppKit
import Foundation
import TunaKit

struct MusicNowPlaying: Equatable, Sendable {
  enum State: Sendable {
    case playing
    case paused
  }

  let state: State
  let persistentID: String
  let title: String
  let artist: String
  let album: String
  let isFavorited: Bool
}

enum MusicScriptError: LocalizedError {
  case musicNotRunning
  case automationDenied
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .musicNotRunning:
      return "Music isn’t running"
    case .automationDenied:
      return "Tuna isn’t allowed to control Music. Allow it under Privacy & Security › Automation."
    case .failed(let message):
      return message
    }
  }
}

/// Every Apple Event the extension sends to Music, plus the scripts behind them.
enum MusicAppleScript {
  static let bundleIdentifier = "com.apple.Music"
  static let helperPlaylistName = "Tuna"
  static let recordSeparator = "\u{1E}"

  // Injectable for tests.
  nonisolated(unsafe) static var runOverride: (@Sendable (String) throws -> String)?
  nonisolated(unsafe) static var isMusicRunningOverride: (@Sendable () -> Bool)?

  static func isMusicRunning() -> Bool {
    if let isMusicRunningOverride {
      return isMusicRunningOverride()
    }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  // MARK: Reads

  static func nowPlaying() throws -> MusicNowPlaying? {
    guard isMusicRunning() else { return nil }
    return parseNowPlaying(try run(Scripts.nowPlaying))
  }

  static func parseNowPlaying(_ output: String) -> MusicNowPlaying? {
    let fields = output.components(separatedBy: recordSeparator)
    guard fields.count == 6 else { return nil }
    let state: MusicNowPlaying.State
    switch fields[0] {
    case "playing", "fast forwarding", "rewinding":
      state = .playing
    case "paused":
      state = .paused
    default:
      return nil
    }
    return MusicNowPlaying(
      state: state,
      persistentID: fields[1],
      title: fields[2],
      artist: fields[3],
      album: fields[4],
      isFavorited: fields[5] == "true"
    )
  }

  // MARK: Playback

  static func playPause() throws { try run(Scripts.command("playpause")) }
  static func nextTrack() throws { try run(Scripts.command("next track")) }
  static func previousTrack() throws { try run(Scripts.command("previous track")) }
  static func toggleShuffle() throws { try run(Scripts.command("set shuffle enabled to not shuffle enabled")) }
  static func toggleRepeat() throws { try run(Scripts.toggleRepeat) }

  static func play(trackID: String) throws {
    try run(Scripts.command("play \(Scripts.track(trackID))"))
  }

  static func play(playlistID: String, shuffle: Bool) throws {
    try run(Scripts.command("set shuffle enabled to \(shuffle)\n  play \(Scripts.playlist(playlistID))"))
  }

  /// Music has no album or artist objects, so those play through a Tuna-owned helper playlist.
  static func play(trackIDs: [String], shuffle: Bool) throws {
    try run(Scripts.playThroughHelperPlaylist(trackIDs: trackIDs, shuffle: shuffle))
  }

  static func reveal(trackID: String) throws {
    try run(Scripts.command("activate\n  reveal \(Scripts.track(trackID))"))
  }

  static func reveal(playlistID: String) throws {
    try run(Scripts.command("activate\n  reveal \(Scripts.playlist(playlistID))"))
  }

  // MARK: Writes

  static func setFavorited(_ favorited: Bool, trackID: String) throws {
    try run(Scripts.command("set favorited of \(Scripts.track(trackID)) to \(favorited)"))
  }

  static func add(trackIDs: [String], toPlaylistID playlistID: String) throws {
    try run(Scripts.addToPlaylist(trackIDs: trackIDs, playlistID: playlistID))
  }

  // MARK: Execution

  @discardableResult
  static func run(_ source: String) throws -> String {
    if let runOverride {
      return try runOverride(source)
    }

    let result: CLIProcessResult
    do {
      result = try CLIProcessRunner.runSync(
        CLIProcessRequest(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
      )
    } catch {
      throw MusicScriptError.failed(error.localizedDescription)
    }

    guard result.succeeded else {
      let message = result.preferredErrorMessage
      if message.contains("-1743") || message.contains("Not authorized") {
        throw MusicScriptError.automationDenied
      }
      throw MusicScriptError.failed(message)
    }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  enum Scripts {
    static let nowPlaying = """
      set RS to character id 30
      tell application "Music"
        set stateText to player state as text
        try
          set t to current track
          return stateText & RS & persistent ID of t & RS & name of t & RS & artist of t & RS & album of t & RS & favorited of t
        on error
          return stateText
        end try
      end tell
      """

    static let toggleRepeat = command(
      """
      if song repeat is off then
          set song repeat to all
        else if song repeat is all then
          set song repeat to one
        else
          set song repeat to off
        end if
      """)

    static func command(_ body: String) -> String {
      """
      tell application "Music"
        \(body)
      end tell
      """
    }

    static func track(_ persistentID: String) -> String {
      "(first track of library playlist 1 whose persistent ID is \(literal(persistentID)))"
    }

    static func playlist(_ persistentID: String) -> String {
      "(first user playlist whose persistent ID is \(literal(persistentID)))"
    }

    static func playThroughHelperPlaylist(trackIDs: [String], shuffle: Bool) -> String {
      let name = literal(MusicAppleScript.helperPlaylistName)
      return command(
        """
        if not (exists user playlist \(name)) then make new user playlist with properties {name:\(name)}
          set queuePlaylist to user playlist \(name)
          delete every track of queuePlaylist
          repeat with trackID in \(list(trackIDs))
            duplicate (first track of library playlist 1 whose persistent ID is trackID) to queuePlaylist
          end repeat
          set shuffle enabled to \(shuffle)
          play queuePlaylist
        """)
    }

    static func addToPlaylist(trackIDs: [String], playlistID: String) -> String {
      command(
        """
        set targetPlaylist to \(playlist(playlistID))
          repeat with trackID in \(list(trackIDs))
            duplicate (first track of library playlist 1 whose persistent ID is trackID) to targetPlaylist
          end repeat
        """)
    }

    static func list(_ strings: [String]) -> String {
      "{" + strings.map(literal).joined(separator: ", ") + "}"
    }

    static func literal(_ string: String) -> String {
      let escaped = string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
      return "\"\(escaped)\""
    }
  }
}
