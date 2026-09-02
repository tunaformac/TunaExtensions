import AppKit
import Foundation
import MusicKit
import TunaKit

/// A catalog result from Apple Music. MusicKit has no library writes on macOS, so results are open-only.
struct AppleMusicEntry: Sendable {
  enum Kind: String, Sendable {
    case song
    case album
    case artist
    case playlist
    case station
  }

  let kind: Kind
  let id: String
  let title: String
  let subtitle: String?
  let url: URL?
  let artwork: Artwork?
}

final class AppleMusicItem: CatalogEntity, CatalogAsyncPreviewProviding, @unchecked Sendable {
  let entry: AppleMusicEntry

  init(entry: AppleMusicEntry) {
    self.entry = entry
    super.init(id: "music.catalog.\(entry.kind.rawValue).\(entry.id)", title: entry.title, path: nil)
    typeID = Self.typeID(for: entry.kind)
  }

  static func typeID(for kind: AppleMusicEntry.Kind) -> TypeID {
    switch kind {
    case .song: return .musicSong
    case .album: return .musicAlbum
    case .artist: return .musicArtist
    case .playlist: return .musicPlaylist
    case .station: return .musicStation
    }
  }

  override var detail: String? { entry.subtitle }

  override var searchText: String {
    MusicFormatting.joined([entry.title, entry.subtitle ?? ""], separator: " ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    let symbol: String
    switch entry.kind {
    case .song: symbol = "music.note"
    case .album: symbol = "square.stack"
    case .artist: symbol = "music.mic"
    case .playlist: symbol = "music.note.list"
    case .station: symbol = "dot.radiowaves.left.and.right"
    }
    return .systemSymbol(symbol, tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MusicArtworkIndex.preview(for: entry.artwork, maxDimension: maxDimension)
  }
}

/// Apple Music search, with Recently Played and For You when the query is empty.
@MainActor
public final class AppleMusicCatalog: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Apple Music",
    id: "music.search",
    detail: "Search Apple Music, or browse Recently Played and For You",
    catalogIcon: .init(symbolName: "music.note", color: .red),
    loadingItemProvider: { AppleMusicClient.loadingItem("Apple Music") },
    errorItemProvider: { AppleMusicClient.messageItem(for: $0) },
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: { [identifier] in
      try await AppleMusicClient.ensureAuthorized()
      return AppleMusicClient.browseRoots(catalogIdentifier: identifier)
    },
    searchHandler: { query in
      try await AppleMusicClient.ensureAuthorized()
      let items = try await AppleMusicClient.search(term: query)
      return items.isEmpty ? [AppleMusicClient.emptyItem("No Results", "Nothing on Apple Music matched your search.")] : items
    }
  )

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func scan() async {
    rootItem.reset()
    reportScanFinished()
  }

  public func releaseRetainedState() {
    rootItem.reset()
  }
}

enum AppleMusicError: LocalizedError {
  case authorizationDenied
  case authorizationRestricted

  var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      return "Allow Tuna to access Apple Music under Privacy & Security › Media & Apple Music."
    case .authorizationRestricted:
      return "Apple Music access is restricted on this Mac."
    }
  }
}

enum AppleMusicClient {
  static let searchLimit = 8

  static func ensureAuthorized() async throws {
    var status = MusicAuthorization.currentStatus
    if status == .notDetermined {
      status = await MusicAuthorization.request()
    }
    switch status {
    case .authorized:
      return
    case .restricted:
      throw AppleMusicError.authorizationRestricted
    default:
      throw AppleMusicError.authorizationDenied
    }
  }

  static func browseRoots(catalogIdentifier: String) -> [CatalogItem] {
    [
      DeferredBrowseCatalogItem(
        title: "Recently Played",
        id: "music.search.recent",
        detail: "Songs you played recently",
        catalogIcon: .init(symbolName: "clock.arrow.circlepath", color: .red),
        loadingItemProvider: { loadingItem("Recently Played") },
        errorItemProvider: { messageItem(for: $0) },
        didLoad: { NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier) },
        loadChildren: {
          let items = try await recentlyPlayed()
          return items.isEmpty ? [emptyItem("Nothing Played Yet", "Recently played songs show up here.")] : items
        }
      ),
      DeferredBrowseCatalogItem(
        title: "For You",
        id: "music.search.recommendations",
        detail: "Albums, playlists, and stations picked for you",
        catalogIcon: .init(symbolName: "sparkles", color: .red),
        loadingItemProvider: { loadingItem("For You") },
        errorItemProvider: { messageItem(for: $0) },
        didLoad: { NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier) },
        loadChildren: {
          let items = try await recommendations()
          return items.isEmpty ? [emptyItem("No Recommendations", "Apple Music has nothing to recommend yet.")] : items
        }
      ),
    ]
  }

  static func search(term: String) async throws -> [CatalogItem] {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var request = MusicCatalogSearchRequest(
      term: trimmed, types: [Song.self, Album.self, Artist.self, Playlist.self, Station.self])
    request.limit = searchLimit
    let response = try await request.response()
    let entries =
      response.songs.map(entry) + response.albums.map(entry) + response.artists.map(entry)
      + response.playlists.map(entry) + response.stations.map(entry)
    return entries.map(AppleMusicItem.init)
  }

  static func recentlyPlayed() async throws -> [CatalogItem] {
    var request = MusicRecentlyPlayedRequest<Song>()
    request.limit = 25
    return try await request.response().items.map { AppleMusicItem(entry: entry($0)) }
  }

  static func recommendations() async throws -> [CatalogItem] {
    let response = try await MusicPersonalRecommendationsRequest().response()
    return response.recommendations.flatMap { recommendation -> [CatalogItem] in
      let context = recommendation.title ?? recommendation.reason
      let entries =
        recommendation.albums.map(entry) + recommendation.playlists.map(entry)
        + recommendation.stations.map(entry)
      return entries.map { entry in
        AppleMusicItem(
          entry: AppleMusicEntry(
            kind: entry.kind, id: entry.id, title: entry.title,
            subtitle: MusicFormatting.joined([entry.subtitle ?? "", context ?? ""], separator: " · "),
            url: entry.url, artwork: entry.artwork))
      }
    }
  }

  static func entry(_ song: Song) -> AppleMusicEntry {
    AppleMusicEntry(
      kind: .song, id: song.id.rawValue, title: song.title,
      subtitle: MusicFormatting.joined([song.artistName, song.albumTitle ?? ""]),
      url: song.url, artwork: song.artwork)
  }

  static func entry(_ album: Album) -> AppleMusicEntry {
    AppleMusicEntry(
      kind: .album, id: album.id.rawValue, title: album.title,
      subtitle: MusicFormatting.joined([album.artistName, "Album"], separator: " · "),
      url: album.url, artwork: album.artwork)
  }

  static func entry(_ artist: Artist) -> AppleMusicEntry {
    AppleMusicEntry(
      kind: .artist, id: artist.id.rawValue, title: artist.name, subtitle: "Artist",
      url: artist.url, artwork: artist.artwork)
  }

  static func entry(_ playlist: Playlist) -> AppleMusicEntry {
    AppleMusicEntry(
      kind: .playlist, id: playlist.id.rawValue, title: playlist.name,
      subtitle: MusicFormatting.joined([playlist.curatorName ?? "", "Playlist"], separator: " · "),
      url: playlist.url, artwork: playlist.artwork)
  }

  static func entry(_ station: Station) -> AppleMusicEntry {
    AppleMusicEntry(
      kind: .station, id: station.id.rawValue, title: station.name, subtitle: "Station",
      url: station.url, artwork: station.artwork)
  }

  static func loadingItem(_ what: String) -> CatalogItem {
    CatalogLoadingItem(title: "Loading \(what)", message: "Asking Apple Music.")
  }

  static func emptyItem(_ title: String, _ message: String) -> CatalogItem {
    CatalogMessageItem(title: title, message: message, symbolName: "music.note", tintColor: .secondaryLabelColor)
  }

  static func messageItem(for error: Error) -> CatalogItem {
    let title: String
    let message: String
    let symbolName: String
    switch error {
    case is AppleMusicError:
      title = "Apple Music Access Needed"
      message = error.localizedDescription
      symbolName = "lock.fill"
    case MusicTokenRequestError.developerTokenRequestFailed:
      title = "Apple Music Not Enabled for Tuna"
      message = "Tuna’s App ID needs the MusicKit service before Apple Music search works."
      symbolName = "key"
    case MusicTokenRequestError.userNotSignedIn:
      title = "Sign In to Apple Music"
      message = "Sign in with your Apple Account in Music, then try again."
      symbolName = "person.crop.circle.badge.exclamationmark"
    default:
      title = "Apple Music Unavailable"
      message = error.localizedDescription
      symbolName = "exclamationmark.triangle"
    }
    return CatalogMessageItem(title: title, message: message, symbolName: symbolName, tintColor: .systemOrange)
  }
}

/// Artwork for library items, matched by album title and artist through MusicKit's library.
/// Best effort: it only runs once Apple Music access is already granted.
actor MusicArtworkIndex {
  static let shared = MusicArtworkIndex()

  private var albums: [String: Artwork]?
  private var playlists: [String: Artwork] = [:]
  private var loadTask: Task<Void, Never>?

  func albumPreview(title: String, artist: String, maxDimension: CGFloat) async -> CatalogItemPreview? {
    await loadIfNeeded()
    return await Self.preview(for: albums?[MusicAlbum.key(title: title, artist: artist)], maxDimension: maxDimension)
  }

  func playlistPreview(name: String, maxDimension: CGFloat) async -> CatalogItemPreview? {
    await loadIfNeeded()
    return await Self.preview(for: playlists[name.lowercased()], maxDimension: maxDimension)
  }

  static func preview(for artwork: Artwork?, maxDimension: CGFloat) async -> CatalogItemPreview? {
    let pixels = max(32, min(1_024, Int((maxDimension * 2).rounded(.up))))
    guard let url = artwork?.url(width: pixels, height: pixels) else { return nil }
    return await URLImagePreviewLoader.shared.preview(for: url, maxDimension: maxDimension)
  }

  private func loadIfNeeded() async {
    if albums != nil { return }
    if let loadTask {
      await loadTask.value
      return
    }
    let task = Task { await load() }
    loadTask = task
    await task.value
    loadTask = nil
  }

  private func load() async {
    guard MusicAuthorization.currentStatus == .authorized else {
      albums = [:]
      return
    }
    do {
      var albumIndex: [String: Artwork] = [:]
      for album in try await MusicLibraryRequest<Album>().response().items {
        guard let artwork = album.artwork else { continue }
        albumIndex[MusicAlbum.key(title: album.title, artist: album.artistName)] = artwork
      }
      var playlistIndex: [String: Artwork] = [:]
      for playlist in try await MusicLibraryRequest<Playlist>().response().items {
        guard let artwork = playlist.artwork else { continue }
        playlistIndex[playlist.name.lowercased()] = artwork
      }
      albums = albumIndex
      playlists = playlistIndex
    } catch {
      AppLog.warning(.library, "Music artwork index unavailable: \(error.localizedDescription)")
      albums = [:]
    }
  }
}
