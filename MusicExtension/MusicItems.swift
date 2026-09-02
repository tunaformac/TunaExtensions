import AppKit
import Foundation
import TunaKit

extension TypeID {
  static let musicSong = TypeID("com.tuna.type.music-song")
  static let musicAlbum = TypeID("com.tuna.type.music-album")
  static let musicArtist = TypeID("com.tuna.type.music-artist")
  static let musicPlaylist = TypeID("com.tuna.type.music-playlist")
  static let musicStation = TypeID("com.tuna.type.music-station")
}

enum MusicFormatting {
  static func joined(_ parts: [String], separator: String = " — ") -> String {
    parts.filter { !$0.isEmpty }.joined(separator: separator)
  }

  static func count(_ count: Int, _ noun: String) -> String {
    "\(count) \(count == 1 ? noun : noun + "s")"
  }
}

final class MusicSongItem: CatalogEntity, TextValueProviding, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  let track: MusicTrack

  init(track: MusicTrack) {
    self.track = track
    super.init(id: "music.song.\(track.persistentID)", title: track.title, path: nil)
    typeID = .musicSong
  }

  var textValue: String { MusicFormatting.joined([track.title, track.artist]) }

  override var detail: String? { MusicFormatting.joined([track.artist, track.album]) }

  override var searchText: String { MusicFormatting.joined([track.title, track.artist, track.album], separator: " ") }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("music.note", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MusicArtworkIndex.shared.albumPreview(
      title: track.album, artist: track.albumArtistOrArtist, maxDimension: maxDimension)
  }
}

final class MusicAlbumItem: CatalogEntity, CatalogHierarchyNode, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  let album: MusicAlbum
  private lazy var songs: [CatalogItem] = album.tracks.map(MusicSongItem.init)

  init(album: MusicAlbum) {
    self.album = album
    super.init(id: "music.album.\(album.catalogID)", title: album.title, path: nil)
    typeID = .musicAlbum
  }

  var trackIDs: [String] { album.tracks.map(\.persistentID) }

  override var detail: String? {
    MusicFormatting.joined(
      [album.artist, album.year > 0 ? String(album.year) : "", MusicFormatting.count(album.tracks.count, "song")],
      separator: " · ")
  }

  override var searchText: String { MusicFormatting.joined([album.title, album.artist], separator: " ") }

  func hierarchyChildren() -> [CatalogItem] { songs }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("square.stack", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MusicArtworkIndex.shared.albumPreview(
      title: album.title, artist: album.artist, maxDimension: maxDimension)
  }
}

final class MusicArtistItem: CatalogEntity, CatalogHierarchyNode, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  let artist: MusicArtist
  private lazy var albums: [CatalogItem] = artist.albums.map(MusicAlbumItem.init)

  init(artist: MusicArtist) {
    self.artist = artist
    super.init(id: "music.artist.\(artist.name.lowercased())", title: artist.name, path: nil)
    typeID = .musicArtist
  }

  var trackIDs: [String] { artist.albums.flatMap { $0.tracks.map(\.persistentID) } }

  override var detail: String? { MusicFormatting.count(artist.albums.count, "album") }

  func hierarchyChildren() -> [CatalogItem] { albums }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("music.mic", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    guard let album = artist.albums.first else { return nil }
    return await MusicArtworkIndex.shared.albumPreview(
      title: album.title, artist: album.artist, maxDimension: maxDimension)
  }
}

final class MusicPlaylistItem: CatalogEntity, CatalogHierarchyNode, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  let playlist: MusicPlaylist
  let tracks: [MusicTrack]
  private lazy var songs: [CatalogItem] = tracks.map(MusicSongItem.init)

  init(playlist: MusicPlaylist, tracks: [MusicTrack]) {
    self.playlist = playlist
    self.tracks = tracks
    super.init(id: "music.playlist.\(playlist.persistentID)", title: playlist.name, path: nil)
    typeID = .musicPlaylist
  }

  override var detail: String? {
    MusicFormatting.joined(
      [MusicFormatting.count(tracks.count, "song"), playlist.isSmart ? "Smart Playlist" : ""],
      separator: " · ")
  }

  func hierarchyChildren() -> [CatalogItem] {
    guard !songs.isEmpty else {
      return [
        CatalogMessageItem(
          title: "Empty Playlist",
          message: "This playlist has no songs.",
          symbolName: "music.note.list",
          tintColor: .secondaryLabelColor
        )
      ]
    }
    return songs
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("music.note.list", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MusicArtworkIndex.shared.playlistPreview(name: playlist.name, maxDimension: maxDimension)
  }
}

final class MusicNowPlayingItem: CatalogEntity, TextValueProviding, CatalogAsyncPreviewProviding,
  @unchecked Sendable
{
  static let identifier = "music.now-playing"
  let nowPlaying: MusicNowPlaying

  init(nowPlaying: MusicNowPlaying) {
    self.nowPlaying = nowPlaying
    super.init(id: Self.identifier, title: "Now Playing", path: nil)
    typeID = .musicSong
    previewIdentityVersion = UInt64(truncatingIfNeeded: "\(nowPlaying.persistentID).\(nowPlaying.state)".hashValue.magnitude)
  }

  var textValue: String { MusicFormatting.joined([nowPlaying.title, nowPlaying.artist]) }

  override var detail: String? {
    MusicFormatting.joined([textValue, nowPlaying.state == .paused ? "Paused" : ""], separator: " · ")
  }

  override var searchText: String {
    MusicFormatting.joined(["Now Playing", nowPlaying.title, nowPlaying.artist], separator: " ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(nowPlaying.state == .playing ? "play.circle" : "pause.circle", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MusicArtworkIndex.shared.albumPreview(
      title: nowPlaying.album, artist: nowPlaying.artist, maxDimension: maxDimension)
  }
}
