import AppKit
import Foundation
import TunaKit

extension TypeID {
  static let spotifyTrack = TypeID("com.tuna.type.spotify-track")
  static let spotifyAlbum = TypeID("com.tuna.type.spotify-album")
  static let spotifyArtist = TypeID("com.tuna.type.spotify-artist")
  static let spotifyPlaylist = TypeID("com.tuna.type.spotify-playlist")
  static let spotifyDevice = TypeID("com.tuna.type.spotify-device")
}

/// A Spotify object named by a `spotify:` URI or an open.spotify.com link.
struct SpotifyURI: Equatable, Sendable {
  static let playableTypes: Set<String> = [
    "track", "album", "artist", "playlist", "episode", "show",
  ]

  let type: String
  let id: String

  var uri: String { "spotify:\(type):\(id)" }
  var webURL: URL { URL(string: "https://open.spotify.com/\(type)/\(id)")! }
  var resourceKind: SpotifyResource.Kind? { SpotifyResource.Kind(rawValue: type) }

  init?(type: String, id: String) {
    guard Self.playableTypes.contains(type), !id.isEmpty,
      id.allSatisfy({ $0.isLetter || $0.isNumber })
    else { return nil }
    self.type = type
    self.id = id
  }

  /// Accepts `spotify:track:ID` and `https://open.spotify.com/[intl-xx/]track/ID?si=…`.
  init?(_ string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("spotify:") {
      let parts = trimmed.split(separator: ":").map(String.init)
      guard parts.count == 3 else { return nil }
      self.init(type: parts[1], id: parts[2])
      return
    }
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "open.spotify.com"
    else { return nil }
    var segments = components.path.split(separator: "/").map(String.init)
    if segments.first?.hasPrefix("intl-") == true { segments.removeFirst() }
    guard segments.count >= 2 else { return nil }
    self.init(type: segments[0], id: segments[1])
  }
}

class SpotifyItem: CatalogEntity, TextValueProviding, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  let resource: SpotifyResource
  let catalogIdentifier: String

  init(resource: SpotifyResource, catalogIdentifier: String) {
    self.resource = resource
    self.catalogIdentifier = catalogIdentifier
    super.init(
      id: "spotify.\(resource.kind.rawValue).\(resource.id)",
      title: resource.title,
      path: resource.externalURL.absoluteString
    )
    typeID = Self.typeID(for: resource.kind)
  }

  static func make(_ resource: SpotifyResource, catalogIdentifier: String) -> SpotifyItem {
    resource.isBrowsable
      ? SpotifyCollectionItem(resource: resource, catalogIdentifier: catalogIdentifier)
      : SpotifyItem(resource: resource, catalogIdentifier: catalogIdentifier)
  }

  var textValue: String { resource.externalURL.absoluteString }

  override var detail: String? { resource.subtitle }

  override var searchText: String { "\(resource.title) \(resource.subtitle)" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(Self.symbol(for: resource.kind), tintColor: .systemGreen)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    guard let artworkURL = resource.artworkURL else { return nil }
    return await SpotifyArtworkLoader.shared.preview(for: artworkURL, maxDimension: maxDimension)
  }

  private static func typeID(for kind: SpotifyResource.Kind) -> TypeID {
    switch kind {
    case .track: return .spotifyTrack
    case .album: return .spotifyAlbum
    case .artist: return .spotifyArtist
    case .playlist: return .spotifyPlaylist
    }
  }

  private static func symbol(for kind: SpotifyResource.Kind) -> String {
    switch kind {
    case .track: return "music.note"
    case .album: return "square.stack"
    case .artist: return "music.mic"
    case .playlist: return "music.note.list"
    }
  }
}

final class SpotifyCollectionItem: SpotifyItem, CatalogHierarchyNode, @unchecked Sendable {
  private lazy var deferredContents = DeferredBrowseCatalogItem(
    title: resource.title,
    id: "spotify.contents.\(resource.kind.rawValue).\(resource.id)",
    detail: "Contents on Spotify",
    catalogIcon: .init(symbolName: "music.note.list", color: .green),
    loadingItemProvider: { SpotifyCatalogSupport.loadingItem("Contents") },
    errorItemProvider: { SpotifyCatalogSupport.messageItem(for: $0) },
    didLoad: { [catalogIdentifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
    },
    loadChildren: { [resource, catalogIdentifier] in
      let children = try await SpotifyAPIClient().children(of: resource)
      return children.isEmpty
        ? [SpotifyCatalogSupport.emptyItem("No Contents", "Spotify returned no items.")]
        : children.map { SpotifyItem.make($0, catalogIdentifier: catalogIdentifier) }
    }
  )

  @MainActor func hierarchyChildren() -> [CatalogItem] {
    deferredContents.hierarchyChildren()
  }
}

final class SpotifyDeviceItem: CatalogEntity, @unchecked Sendable {
  let device: SpotifyDevice

  init(device: SpotifyDevice) {
    self.device = device
    super.init(id: "spotify.device.\(device.id)", title: device.name, path: nil)
    typeID = .spotifyDevice
  }

  override var detail: String? {
    [device.type, device.isActive ? "Active" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(
      device.isActive ? "speaker.wave.2.fill" : "speaker.wave.2", tintColor: .systemGreen)
  }
}

final class SpotifyNowPlayingItem: CatalogEntity, TextValueProviding, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  static let identifier = "spotify.now-playing"
  let nowPlaying: SpotifyNowPlaying

  init(nowPlaying: SpotifyNowPlaying) {
    self.nowPlaying = nowPlaying
    let url = SpotifyURI(nowPlaying.uri)?.webURL
    super.init(id: Self.identifier, title: "Now Playing", path: url?.absoluteString)
    typeID = .spotifyTrack
    previewIdentityVersion = UInt64(
      truncatingIfNeeded: "\(nowPlaying.uri).\(nowPlaying.state)".hashValue.magnitude)
  }

  var textValue: String { [nowPlaying.title, nowPlaying.artist].joined(separator: " — ") }

  /// The playing track as a Web API resource, for Save to Library. Nil for ads and local files.
  var resource: SpotifyResource? {
    guard let uri = SpotifyURI(nowPlaying.uri), uri.type == "track" else { return nil }
    return SpotifyResource(
      kind: .track,
      id: uri.id,
      title: nowPlaying.title,
      subtitle: nowPlaying.artist,
      uri: uri.uri,
      externalURL: uri.webURL,
      artworkURL: nowPlaying.artworkURL,
      isSaved: nil,
      isBrowsable: false,
      canModifyPlaylist: false
    )
  }

  override var detail: String? {
    [textValue, nowPlaying.state == .paused ? "Paused" : ""].filter { !$0.isEmpty }.joined(
      separator: " · ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(
      nowPlaying.state == .playing ? "play.circle" : "pause.circle", tintColor: .systemGreen)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    guard let url = nowPlaying.artworkURL else { return nil }
    return await SpotifyArtworkLoader.shared.preview(for: url, maxDimension: maxDimension)
  }
}

actor SpotifyArtworkLoader {
  static let shared = SpotifyArtworkLoader()
  private var cache: [URL: Data?] = [:]

  func preview(for url: URL, maxDimension: CGFloat) async -> CatalogItemPreview? {
    let data: Data?
    if let cached = cache[url] {
      data = cached
    } else {
      data = try? await URLSession.shared.data(from: url).0
      cache[url] = data
    }
    guard let data, let image = NSImage(data: data) else { return nil }
    return CatalogItemPreview(image: image)
  }
}
