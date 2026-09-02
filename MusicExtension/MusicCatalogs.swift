import AppKit
import Foundation
import TunaKit

/// Now Playing plus transport commands. Refreshes when Music broadcasts a player change.
@MainActor
public final class MusicControlsCatalog: NSObject, Catalog, RescanSchedulingCatalog {
  public static let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")

  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?

  private var nowPlayingItem: CatalogItem?
  private lazy var commands = Self.makeCommands()
  private var playerObserver: NSObjectProtocol?
  private var refreshTask: Task<Void, Never>?

  public var objects: [CatalogItem] {
    (nowPlayingItem.map { [$0] } ?? []) + commands
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
    playerObserver = DistributedNotificationCenter.default().addObserver(
      forName: Self.playerInfoNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }
  }

  deinit {
    if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver) }
    refreshTask?.cancel()
  }

  public func scan() async {
    let nowPlaying = await Task.detached(priority: .utility) { try? MusicAppleScript.nowPlaying() }.value
    nowPlayingItem = (nowPlaying ?? nil).map(MusicNowPlayingItem.init)
    reportScanFinished()
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.rescanHandler?()
    }
  }

  nonisolated static func makeCommands() -> [CatalogItem] {
    let definitions: [(id: String, title: String, symbol: String, detail: String, run: @Sendable () throws -> Void)] = [
      ("play-pause", "Play/Pause", "playpause", "Play or pause Music", { try MusicAppleScript.playPause() }),
      ("next-track", "Next Track", "forward.end", "Skip to the next track", { try MusicAppleScript.nextTrack() }),
      ("previous-track", "Previous Track", "backward.end", "Go back to the previous track", { try MusicAppleScript.previousTrack() }),
      ("toggle-shuffle", "Toggle Shuffle", "shuffle", "Turn shuffle on or off", { try MusicAppleScript.toggleShuffle() }),
      ("toggle-repeat", "Toggle Repeat", "repeat", "Cycle repeat through off, all, and one", { try MusicAppleScript.toggleRepeat() }),
    ]
    return definitions.map { definition in
      CommandItem(
        id: definition.id,
        title: definition.title,
        symbol: definition.symbol,
        detail: definition.detail,
        tintColor: .systemRed,
        headlessEligibility: .guaranteed,
        executionPolicy: .dismiss
      ) {
        MusicActions.perform(definition.run)
      }
    }
  }
}

public final class MusicSongsCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .songs, mode: .all, store: .shared)
  }
}

public final class MusicSongsBrowseCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .songs, mode: .browse, store: .shared)
  }
}

public final class MusicAlbumsCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .albums, mode: .all, store: .shared)
  }
}

public final class MusicAlbumsBrowseCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .albums, mode: .browse, store: .shared)
  }
}

public final class MusicArtistsCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .artists, mode: .all, store: .shared)
  }
}

public final class MusicArtistsBrowseCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .artists, mode: .browse, store: .shared)
  }
}

public final class MusicPlaylistsCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .playlists, mode: .all, store: .shared)
  }
}

public final class MusicPlaylistsBrowseCatalog: MusicLibraryCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, section: .playlists, mode: .browse, store: .shared)
  }
}

/// One library snapshot feeds songs, albums, artists, and playlists. Each section has a content
/// catalog (`.all`) and a browse root (`.browse`); Tuna keeps browse-root contents out of global
/// search until the user opts them in.
@MainActor
public class MusicLibraryCatalogBase: NSObject, Catalog, RescanSchedulingCatalog {
  enum Section {
    case songs
    case albums
    case artists
    case playlists

    var title: String {
      switch self {
      case .songs: return "Songs"
      case .albums: return "Albums"
      case .artists: return "Artists"
      case .playlists: return "Playlists"
      }
    }

    var rootID: String { "music.\(title.lowercased())" }

    var symbolName: String {
      switch self {
      case .songs: return "music.note"
      case .albums: return "square.stack"
      case .artists: return "music.mic"
      case .playlists: return "music.note.list"
      }
    }

    var rootDetail: String {
      "Browse and search \(title.lowercased()) in your Music library"
    }
  }

  enum Mode {
    case all
    case browse
  }

  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?

  private let section: Section
  private let mode: Mode
  private let store: MusicLibraryStore
  private var items: [CatalogItem] = []
  private var changeObserver: NSObjectProtocol?

  private lazy var browseRoot = BrowseCatalogItem(
    title: section.title,
    id: section.rootID,
    detail: section.rootDetail,
    catalogIcon: .init(symbolName: section.symbolName, color: .red)
  ) { [weak self] in
    self?.items ?? []
  }

  public var objects: [CatalogItem] {
    mode == .browse ? [browseRoot] : items
  }

  init(definition: CatalogDefinition, section: Section, mode: Mode, store: MusicLibraryStore) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.section = section
    self.mode = mode
    self.store = store
    super.init()
    if mode == .browse {
      items = [CatalogLoadingItem(title: "Loading \(section.title)", message: "Reading your Music library.")]
    }
    changeObserver = NotificationCenter.default.addObserver(
      forName: .musicLibraryDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rescanHandler?() }
    }
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Music catalog type instead.")
  }

  deinit {
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  public func scan() async {
    store.startWatching()
    let load = await store.load()
    let built = await Task.detached(priority: .utility) { [section, mode] in
      UncheckedSendableBox(Self.buildItems(for: section, mode: mode, load: load))
    }.value
    items = built.value
    reportScanFinished()
  }

  nonisolated static func buildItems(for section: Section, mode: Mode, load: MusicLibraryStore.Load) -> [CatalogItem] {
    guard let snapshot = load.snapshot else {
      return mode == .browse ? [unavailableItem(for: load)] : []
    }
    let items: [CatalogItem]
    switch section {
    case .songs:
      items = snapshot.tracks
        .sorted { $0.title.lowercased() < $1.title.lowercased() }
        .map(MusicSongItem.init)
    case .albums:
      items = snapshot.albums().map(MusicAlbumItem.init)
    case .artists:
      items = snapshot.artists().map(MusicArtistItem.init)
    case .playlists:
      items = snapshot.playlists.map {
        MusicPlaylistItem(playlist: $0, tracks: snapshot.tracks(withPersistentIDs: $0.trackPersistentIDs))
      }
    }
    if items.isEmpty, mode == .browse {
      return [
        CatalogMessageItem(
          title: "No \(section.title)",
          message: "Your Music library has no \(section.title.lowercased()) yet.",
          symbolName: section.symbolName,
          tintColor: .secondaryLabelColor
        )
      ]
    }
    return items
  }

  nonisolated static func unavailableItem(for load: MusicLibraryStore.Load) -> CatalogItem {
    if let errorMessage = load.errorMessage {
      return CatalogMessageItem(
        title: "Couldn’t Read Music Library",
        message: errorMessage,
        symbolName: "exclamationmark.triangle",
        tintColor: .systemOrange
      )
    }
    return CatalogMessageItem(
      title: "Music Isn’t Running",
      message: "Open Music once so Tuna can read your library.",
      symbolName: "music.note",
      tintColor: .secondaryLabelColor
    )
  }
}
