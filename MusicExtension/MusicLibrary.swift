import Foundation
import TunaKit

struct MusicTrack: Codable, Hashable, Sendable {
  let persistentID: String
  let title: String
  let artist: String
  let albumArtist: String
  let album: String
  let trackNumber: Int
  let discNumber: Int
  let year: Int
  let duration: TimeInterval
  let isFavorited: Bool

  /// The artist Music groups the album under, falling back to the track artist.
  var albumArtistOrArtist: String { albumArtist.isEmpty ? artist : albumArtist }
}

struct MusicPlaylist: Codable, Hashable, Sendable {
  let persistentID: String
  let name: String
  let isSmart: Bool
  let trackPersistentIDs: [String]
}

struct MusicAlbum: Hashable, Sendable {
  let title: String
  let artist: String
  let year: Int
  let tracks: [MusicTrack]

  static func key(title: String, artist: String) -> String {
    "\(artist.lowercased())\u{1F}\(title.lowercased())"
  }

  var key: String { Self.key(title: title, artist: artist) }
  var catalogID: String { Data(key.utf8).base64EncodedString() }
}

struct MusicArtist: Hashable, Sendable {
  let name: String
  let albums: [MusicAlbum]
}

struct MusicLibrarySnapshot: Codable, Sendable {
  var tracks: [MusicTrack]
  var playlists: [MusicPlaylist]
  var capturedAt: Date

  func albums() -> [MusicAlbum] {
    var grouped: [String: [MusicTrack]] = [:]
    for track in tracks where !track.album.isEmpty {
      grouped[MusicAlbum.key(title: track.album, artist: track.albumArtistOrArtist), default: []]
        .append(track)
    }

    return grouped.values
      .map { albumTracks in
        let sorted = albumTracks.sorted {
          ($0.discNumber, $0.trackNumber, $0.title.lowercased())
            < ($1.discNumber, $1.trackNumber, $1.title.lowercased())
        }
        let first = sorted[0]
        return MusicAlbum(
          title: first.album,
          artist: first.albumArtistOrArtist,
          year: sorted.map(\.year).filter { $0 > 0 }.min() ?? 0,
          tracks: sorted
        )
      }
      .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
  }

  func artists() -> [MusicArtist] {
    var grouped: [String: [MusicAlbum]] = [:]
    for album in albums() where !album.artist.isEmpty {
      grouped[album.artist.lowercased(), default: []].append(album)
    }
    return grouped.values
      .map { albums in
        MusicArtist(
          name: albums[0].artist,
          albums: albums.sorted { ($0.year, $0.title.lowercased()) < ($1.year, $1.title.lowercased()) }
        )
      }
      .sorted { $0.name.lowercased() < $1.name.lowercased() }
  }

  func tracks(withPersistentIDs identifiers: [String]) -> [MusicTrack] {
    let byID = Dictionary(tracks.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
    return identifiers.compactMap { byID[$0] }
  }
}

/// The single AppleScript that dumps the library, and the parser for its delimited output.
enum MusicLibraryDump {
  static let recordSeparator = "\u{1E}"
  static let groupSeparator = "\u{1D}"
  static let sectionSeparator = "\u{1C}"

  static let script = """
    set RS to character id 30
    set GS to character id 29
    set FS to character id 28
    tell application "Music"
      tell library playlist 1
        set songNames to name of (every track whose media kind is song)
        set songArtists to artist of (every track whose media kind is song)
        set songAlbumArtists to album artist of (every track whose media kind is song)
        set songAlbums to album of (every track whose media kind is song)
        set songTrackNumbers to track number of (every track whose media kind is song)
        set songDiscNumbers to disc number of (every track whose media kind is song)
        set songYears to year of (every track whose media kind is song)
        set songDurations to duration of (every track whose media kind is song)
        set songFavorites to favorited of (every track whose media kind is song)
        set songIDs to persistent ID of (every track whose media kind is song)
      end tell
      set playlistText to ""
      repeat with aPlaylist in (every user playlist whose special kind is none)
        set trackIDText to ""
        if (count of tracks of aPlaylist) > 0 then
          set AppleScript's text item delimiters to ","
          set trackIDText to (get persistent ID of every track of aPlaylist) as text
          set AppleScript's text item delimiters to ""
        end if
        set playlistText to playlistText & (name of aPlaylist) & RS & (persistent ID of aPlaylist) & RS & (smart of aPlaylist) & RS & trackIDText & GS
      end repeat
    end tell
    set AppleScript's text item delimiters to RS
    set trackText to (songNames as text) & GS & (songArtists as text) & GS & (songAlbumArtists as text) & GS & (songAlbums as text) & GS & (songTrackNumbers as text) & GS & (songDiscNumbers as text) & GS & (songYears as text) & GS & (songDurations as text) & GS & (songFavorites as text) & GS & (songIDs as text)
    set AppleScript's text item delimiters to ""
    return trackText & FS & playlistText
    """

  struct ParseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func parse(_ output: String, capturedAt: Date = Date()) throws -> MusicLibrarySnapshot {
    let sections = output.components(separatedBy: sectionSeparator)
    guard sections.count == 2 else {
      throw ParseError(message: "Unexpected library dump layout")
    }
    return MusicLibrarySnapshot(
      tracks: try parseTracks(sections[0]),
      playlists: parsePlaylists(sections[1]),
      capturedAt: capturedAt
    )
  }

  private static func parseTracks(_ text: String) throws -> [MusicTrack] {
    let columns = text.components(separatedBy: groupSeparator).map(splitRecords)
    guard columns.count == 10 else {
      throw ParseError(message: "Expected 10 track columns, got \(columns.count)")
    }
    let count = columns[9].count
    guard columns.allSatisfy({ $0.count == count }) else {
      throw ParseError(message: "Track columns have mismatched lengths")
    }
    return (0..<count).map { index in
      MusicTrack(
        persistentID: columns[9][index],
        title: columns[0][index],
        artist: columns[1][index],
        albumArtist: columns[2][index],
        album: columns[3][index],
        trackNumber: Int(columns[4][index]) ?? 0,
        discNumber: Int(columns[5][index]) ?? 0,
        year: Int(columns[6][index]) ?? 0,
        duration: number(columns[7][index]),
        isFavorited: columns[8][index] == "true"
      )
    }
  }

  private static func parsePlaylists(_ text: String) -> [MusicPlaylist] {
    text.components(separatedBy: groupSeparator).compactMap { record in
      let fields = record.components(separatedBy: recordSeparator)
      guard fields.count == 4, !fields[1].isEmpty else { return nil }
      return MusicPlaylist(
        persistentID: fields[1],
        name: fields[0],
        isSmart: fields[2] == "true",
        trackPersistentIDs: fields[3].isEmpty ? [] : fields[3].components(separatedBy: ",")
      )
    }
  }

  private static func splitRecords(_ text: String) -> [String] {
    text.isEmpty ? [] : text.components(separatedBy: recordSeparator)
  }

  /// AppleScript formats reals with the user's decimal separator.
  private static func number(_ text: String) -> Double {
    Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
  }
}

extension Notification.Name {
  static let musicLibraryDidChange = Notification.Name("com.brnbw.tuna.music.libraryDidChange")
}

/// Loads the library once per scan cycle for every library catalog, and keeps the last good
/// snapshot on disk so songs stay searchable while Music is closed.
@MainActor
final class MusicLibraryStore {
  static let shared = MusicLibraryStore()

  enum Source: Sendable {
    case live
    case cached
    case unavailable
  }

  struct Load: Sendable {
    let snapshot: MusicLibrarySnapshot?
    let source: Source
    let errorMessage: String?
  }

  private let cacheURL: URL
  private var latest: Load?
  private var latestAt = Date.distantPast
  private var inFlight: Task<Load, Never>?
  private var watcher: DispatchSourceFileSystemObject?
  private var changeTask: Task<Void, Never>?

  nonisolated static var defaultCacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tuna/Music", isDirectory: true)
      .appendingPathComponent("library.json")
  }

  nonisolated static var libraryPackageURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Music/Music/Music Library.musiclibrary", isDirectory: true)
  }

  init(cacheURL: URL = MusicLibraryStore.defaultCacheURL) {
    self.cacheURL = cacheURL
  }

  deinit {
    watcher?.cancel()
    changeTask?.cancel()
  }

  func load(maxAge: TimeInterval = 10) async -> Load {
    if let latest, Date().timeIntervalSince(latestAt) < maxAge {
      return latest
    }
    if let inFlight {
      return await inFlight.value
    }
    let cacheURL = self.cacheURL
    let task = Task.detached(priority: .utility) { Self.performLoad(cacheURL: cacheURL) }
    inFlight = task
    let load = await task.value
    inFlight = nil
    latest = load
    latestAt = Date()
    return load
  }

  func invalidate() {
    latest = nil
  }

  nonisolated static func performLoad(cacheURL: URL) -> Load {
    guard MusicAppleScript.isMusicRunning() else {
      return fallback(cacheURL: cacheURL, errorMessage: nil)
    }
    do {
      let snapshot = try MusicLibraryDump.parse(try MusicAppleScript.run(MusicLibraryDump.script))
      writeCache(snapshot, to: cacheURL)
      return Load(snapshot: snapshot, source: .live, errorMessage: nil)
    } catch {
      AppLog.error(.library, "Music library dump failed: \(error.localizedDescription)")
      return fallback(cacheURL: cacheURL, errorMessage: error.localizedDescription)
    }
  }

  nonisolated private static func fallback(cacheURL: URL, errorMessage: String?) -> Load {
    guard let data = try? Data(contentsOf: cacheURL),
      let snapshot = try? JSONDecoder().decode(MusicLibrarySnapshot.self, from: data)
    else {
      return Load(snapshot: nil, source: .unavailable, errorMessage: errorMessage)
    }
    return Load(snapshot: snapshot, source: .cached, errorMessage: errorMessage)
  }

  nonisolated private static func writeCache(_ snapshot: MusicLibrarySnapshot, to cacheURL: URL) {
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
    } catch {
      AppLog.warning(.library, "Music library cache not written: \(error.localizedDescription)")
    }
  }

  /// Posts `.musicLibraryDidChange` when Music rewrites its library package.
  func startWatching(packageURL: URL = MusicLibraryStore.libraryPackageURL) {
    guard watcher == nil else { return }
    let descriptor = open(packageURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.scheduleChangeNotification() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    watcher = source
  }

  private func scheduleChangeNotification() {
    changeTask?.cancel()
    changeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.invalidate()
      NotificationCenter.default.post(name: .musicLibraryDidChange, object: nil)
    }
  }
}
