import AppKit
import Foundation
import TunaKit

public final class MusicActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  static let libraryTypes: Set<TypeID> = [.musicSong, .musicAlbum, .musicArtist, .musicPlaylist]
  static let catalogTypes: Set<TypeID> = [.musicSong, .musicAlbum, .musicArtist, .musicPlaylist, .musicStation]

  static func makeActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let play = PredicateAwareAction(id: "play", title: "Play") { subject, _ in
      MusicActions.play(subject, shuffle: false)
    }
    play.systemSymbolName = "play.fill"
    play.supportedSubjectTypes = libraryTypes
    play.subjectPredicate = MusicActions.isPlayable
    items.append(play)

    let shuffle = PredicateAwareAction(id: "shuffle", title: "Shuffle") { subject, _ in
      MusicActions.play(subject, shuffle: true)
    }
    shuffle.systemSymbolName = "shuffle"
    shuffle.supportedSubjectTypes = [.musicAlbum, .musicArtist, .musicPlaylist]
    shuffle.subjectPredicate = { $0 is MusicAlbumItem || $0 is MusicArtistItem || $0 is MusicPlaylistItem }
    items.append(shuffle)

    let showInMusic = PredicateAwareAction(id: "show-in-music", title: "Show in Music") { subject, _ in
      MusicActions.reveal(subject)
    }
    showInMusic.systemSymbolName = "arrow.up.right.square"
    showInMusic.supportedSubjectTypes = libraryTypes
    showInMusic.subjectPredicate = MusicActions.isPlayable
    items.append(showInMusic)

    let favorite = PredicateAwareAction(id: "favorite", title: "Favorite") { subject, _ in
      MusicActions.setFavorited(true, subject)
    }
    favorite.systemSymbolName = "star"
    favorite.supportedSubjectTypes = [.musicSong]
    favorite.subjectPredicate = { MusicActions.favoriteState(of: $0) == false }
    items.append(favorite)

    let unfavorite = PredicateAwareAction(id: "unfavorite", title: "Unfavorite") { subject, _ in
      MusicActions.setFavorited(false, subject)
    }
    unfavorite.systemSymbolName = "star.slash"
    unfavorite.supportedSubjectTypes = [.musicSong]
    unfavorite.subjectPredicate = { MusicActions.favoriteState(of: $0) == true }
    items.append(unfavorite)

    let addToPlaylist = PredicateAwareAction(id: "add-to-playlist", title: "Add to Playlist") { subject, target in
      MusicActions.add([subject], to: target)
    }
    addToPlaylist.batchCallback = { subjects, target in
      MusicActions.add(subjects, to: target)
    }
    addToPlaylist.targetRequirement = .required
    addToPlaylist.systemSymbolName = "text.badge.plus"
    addToPlaylist.supportedSubjectTypes = [.musicSong, .musicAlbum]
    addToPlaylist.allowedTargetTypes = [.musicPlaylist]
    addToPlaylist.targetSearchScope = .catalogs([MusicExtension.playlistsCatalogIdentifier], preparation: .refresh)
    addToPlaylist.subjectPredicate = { !MusicActions.trackIDs(of: $0).isEmpty }
    addToPlaylist.targetPredicate = { ($0 as? MusicPlaylistItem)?.playlist.isSmart == false }
    items.append(addToPlaylist)

    let openInMusic = PredicateAwareAction(id: "open-in-music", title: "Open in Music") { subject, _ in
      guard let url = (subject as? AppleMusicItem)?.entry.url else {
        return .failure("No Apple Music link available")
      }
      guard let musicURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicAppleScript.bundleIdentifier) else {
        return .failure("Music is not available")
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open([url], withApplicationAt: musicURL, configuration: configuration)
      return .success
    }
    openInMusic.systemSymbolName = "arrow.up.right.square"
    openInMusic.supportedSubjectTypes = catalogTypes
    openInMusic.subjectPredicate = { ($0 as? AppleMusicItem)?.entry.url != nil }
    items.append(openInMusic)

    let transport: [(id: String, title: String, symbol: String, run: @Sendable () throws -> Void)] = [
      ("play-pause", "Play/Pause", "playpause", { try MusicAppleScript.playPause() }),
      ("next-track", "Next Track", "forward.end", { try MusicAppleScript.nextTrack() }),
      ("previous-track", "Previous Track", "backward.end", { try MusicAppleScript.previousTrack() }),
    ]
    for command in transport {
      let action = PredicateAwareAction(id: command.id, title: command.title) { _, _ in
        MusicActions.perform(command.run)
      }
      action.systemSymbolName = command.symbol
      action.supportedSubjectTypes = [.application]
      action.subjectPredicate = MusicActions.isMusicApplication
      items.append(action)
    }

    return items
  }
}

enum MusicActions {
  /// Runs an Apple Event off the main actor. Failures are logged and beeped, like Reminders.
  static func perform(_ work: @escaping @Sendable () throws -> Void) -> ActionResult {
    Task.detached(priority: .userInitiated) {
      do {
        try work()
      } catch {
        AppLog.error(.actions, "Music action failed: \(error.localizedDescription)")
        UserFeedback.beep()
      }
    }
    return .success
  }

  static func isPlayable(_ subject: CatalogItem?) -> Bool {
    subject is MusicSongItem || subject is MusicAlbumItem || subject is MusicArtistItem
      || subject is MusicPlaylistItem || subject is MusicNowPlayingItem
  }

  static func trackIDs(of subject: CatalogItem?) -> [String] {
    switch subject {
    case let song as MusicSongItem: return [song.track.persistentID]
    case let album as MusicAlbumItem: return album.trackIDs
    case let artist as MusicArtistItem: return artist.trackIDs
    case let nowPlaying as MusicNowPlayingItem: return [nowPlaying.nowPlaying.persistentID]
    default: return []
    }
  }

  static func favoriteState(of subject: CatalogItem?) -> Bool? {
    switch subject {
    case let song as MusicSongItem: return song.track.isFavorited
    case let nowPlaying as MusicNowPlayingItem: return nowPlaying.nowPlaying.isFavorited
    default: return nil
    }
  }

  static func play(_ subject: CatalogItem, shuffle: Bool) -> ActionResult {
    switch subject {
    case is MusicNowPlayingItem:
      return perform { try MusicAppleScript.playPause() }
    case let song as MusicSongItem:
      return perform { try MusicAppleScript.play(trackID: song.track.persistentID) }
    case let playlist as MusicPlaylistItem:
      return perform { try MusicAppleScript.play(playlistID: playlist.playlist.persistentID, shuffle: shuffle) }
    default:
      let trackIDs = trackIDs(of: subject)
      guard !trackIDs.isEmpty else { return .failure("Nothing to play") }
      return perform { try MusicAppleScript.play(trackIDs: trackIDs, shuffle: shuffle) }
    }
  }

  static func reveal(_ subject: CatalogItem) -> ActionResult {
    if let playlist = subject as? MusicPlaylistItem {
      return perform { try MusicAppleScript.reveal(playlistID: playlist.playlist.persistentID) }
    }
    guard let trackID = trackIDs(of: subject).first else { return .failure("Nothing to show") }
    return perform { try MusicAppleScript.reveal(trackID: trackID) }
  }

  static func setFavorited(_ favorited: Bool, _ subject: CatalogItem) -> ActionResult {
    guard let trackID = trackIDs(of: subject).first else { return .failure("Select a song first") }
    return perform { try MusicAppleScript.setFavorited(favorited, trackID: trackID) }
  }

  static func add(_ subjects: [CatalogItem], to target: CatalogItem?) -> ActionResult {
    guard let playlist = target as? MusicPlaylistItem, !playlist.playlist.isSmart else {
      return .failure("Select a regular playlist")
    }
    let trackIDs = subjects.flatMap(trackIDs)
    guard !trackIDs.isEmpty else { return .failure("Select songs or albums first") }
    return perform { try MusicAppleScript.add(trackIDs: trackIDs, toPlaylistID: playlist.playlist.persistentID) }
  }

  static func isMusicApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == MusicAppleScript.bundleIdentifier
  }
}
